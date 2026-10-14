import Foundation

enum FanMode {
    case auto    // 0
    case system  // 3, thermalmonitord in charge (idle state on M3+)
    case manual  // 1

    init(raw: Double) {
        switch Int(raw) {
        case 1: self = .manual
        case 3: self = .system
        default: self = .auto
        }
    }
}

struct Fan {
    let index: Int
    let name: String?
    let actual: Double
    let minimum: Double
    let maximum: Double
    let target: Double
    let mode: FanMode

    var label: String {
        if let name, !name.isEmpty { return "Fan \(index) (\(name))" }
        return "Fan \(index)"
    }

    func rpm(forPercent pct: Double) -> Double {
        minimum + (maximum - minimum) * max(0, min(100, pct)) / 100
    }
}

// Writes only F?Md/F?md, F?Tg, Ftst (Apple Silicon) or FS! (Intel). RPM is clamped
// to the firmware's min/max.
//
// M1/M2 accept a direct mode write. From M3 on, thermalmonitord holds mode 3 and
// rejects the write until Ftst is set; the mode then drops to 0 a few seconds later
// and can be forced to 1. Direct write is tried first, Ftst only on refusal.
final class FanController {
    private enum Scheme {
        case modeKey(upper: Bool)  // F?Md, or F?md on newer firmware
        case forceMask             // Intel FS! bitmask
    }

    private let smc: SMC
    private let scheme: Scheme
    private let hasUnlockKey: Bool
    let count: Int

    init(smc: SMC) throws {
        self.smc = smc
        count = Int(try smc.readNumber(FourCC("FNum")))
        guard count > 0 else { throw MacFanError("this Mac reports no fans") }

        if smc.hasKey(FourCC("F0Md")) {
            scheme = .modeKey(upper: true)
        } else if smc.hasKey(FourCC("F0md")) {
            scheme = .modeKey(upper: false)
        } else {
            scheme = .forceMask
        }
        hasUnlockKey = smc.hasKey(FourCC("Ftst"))
    }

    // MARK: Reading

    func fans() throws -> [Fan] {
        try (0..<count).map(fan(at:))
    }

    func fan(at i: Int) throws -> Fan {
        try requireValidIndex(i)
        let actual = try smc.readNumber(FourCC("F\(i)Ac"))
        return Fan(
            index: i,
            name: fanName(i),
            actual: actual,
            minimum: try smc.readNumber(FourCC("F\(i)Mn")),
            maximum: try smc.readNumber(FourCC("F\(i)Mx")),
            target: (try? smc.readNumber(FourCC("F\(i)Tg"))) ?? actual,
            mode: try mode(of: i)
        )
    }

    func mode(of i: Int) throws -> FanMode {
        switch scheme {
        case .modeKey:
            return FanMode(raw: try smc.readNumber(modeKey(i)))
        case .forceMask:
            guard smc.hasKey(FourCC("FS! ")) else { return .auto }
            let mask = UInt16(try smc.readNumber(FourCC("FS! ")))
            return mask & (1 << UInt16(i)) == 0 ? .auto : .manual
        }
    }

    /// False if any fan is forced or the Ftst unlock flag is still set.
    func isReleased(_ indices: [Int]? = nil) throws -> Bool {
        let indices = indices ?? Array(0..<count)
        for i in indices where try mode(of: i) == .manual { return false }
        if case .modeKey = scheme, hasUnlockKey,
           try (0..<count).allSatisfy({ try mode(of: $0) != .manual }),
           try smc.readNumber(FourCC("Ftst")) != 0 {
            return false
        }
        return true
    }

    // MARK: Writing

    /// Returns the RPM actually applied after clamping.
    @discardableResult
    func setSpeed(fan i: Int, rpm: Double) throws -> Double {
        try requireRoot()
        try requireValidIndex(i)
        let minimum = try smc.readNumber(FourCC("F\(i)Mn"))
        let maximum = try smc.readNumber(FourCC("F\(i)Mx"))
        let clamped = max(minimum, min(maximum, rpm.rounded()))

        try enterManual(fan: i)
        try smc.writeNumber(FourCC("F\(i)Tg"), clamped)
        return clamped
    }

    /// Hands fans back to the system and verifies by reading the keys back.
    /// Readback can lag a write, so this retries for a few seconds.
    func restoreDefault(fans selected: [Int]? = nil) throws {
        try requireRoot()
        let indices = selected ?? Array(0..<count)
        for i in indices { try requireValidIndex(i) }

        switch scheme {
        case .forceMask:
            var mask = UInt16(try smc.readNumber(FourCC("FS! ")))
            for i in indices { mask &= ~(1 << UInt16(i)) }
            try smc.writeNumber(FourCC("FS! "), Double(mask))

        case .modeKey:
            let deadline = Date().addingTimeInterval(5)
            repeat {
                for i in indices where try mode(of: i) == .manual {
                    try smc.writeNumber(modeKey(i), 0)
                }
                // Ftst is global; clear it only when no fan at all is forced.
                let othersForced = try (0..<count)
                    .filter { !indices.contains($0) }
                    .contains { try mode(of: $0) == .manual }
                if hasUnlockKey, !othersForced, try smc.readNumber(FourCC("Ftst")) != 0 {
                    try smc.writeNumber(FourCC("Ftst"), 0)
                }
                if try isReleased(indices) { return }
                usleep(250_000)
            } while Date() < deadline
            throw MacFanError("firmware did not release fan control; try again: sudo macfan default")
        }
    }

    private func enterManual(fan i: Int) throws {
        switch scheme {
        case .forceMask:
            let mask = UInt16(try smc.readNumber(FourCC("FS! ")))
            try smc.writeNumber(FourCC("FS! "), Double(mask | (1 << UInt16(i))))

        case .modeKey:
            if try mode(of: i) == .manual { return }
            let key = modeKey(i)

            if (try? smc.writeNumber(key, 1)) != nil, try mode(of: i) == .manual { return }

            guard hasUnlockKey else {
                throw MacFanError("firmware refused manual mode for fan \(i)")
            }

            try smc.writeNumber(FourCC("Ftst"), 1)
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if try mode(of: i) != .system,
                   (try? smc.writeNumber(key, 1)) != nil,
                   try mode(of: i) == .manual {
                    return
                }
                usleep(100_000)
            }
            try? smc.writeNumber(FourCC("Ftst"), 0)
            throw MacFanError("fan \(i) did not accept manual mode within 10s")
        }
    }

    // MARK: Helpers

    private func modeKey(_ i: Int) -> FourCC {
        if case .modeKey(let upper) = scheme, !upper { return FourCC("F\(i)md") }
        return FourCC("F\(i)Md")
    }

    /// Intel fan descriptors carry a location string such as "Left".
    private func fanName(_ i: Int) -> String? {
        guard let (info, bytes) = try? smc.readBytes(FourCC("F\(i)ID")),
              info.type.description == "{fds", bytes.count >= 16 else { return nil }
        let name = String(decoding: bytes[4..<16].prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private func requireRoot() throws {
        guard getuid() == 0 else { throw SMCError.notPrivileged }
    }

    private func requireValidIndex(_ i: Int) throws {
        guard (0..<count).contains(i) else { throw MacFanError("no such fan: \(i) (this Mac has \(count))") }
    }
}

struct MacFanError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
