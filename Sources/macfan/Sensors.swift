import Foundation

struct Sensor {
    let key: String
    let group: String
    let celsius: Double
}

/// Finds temperature keys by walking the SMC key table, so no per-model key list is needed.
final class Thermometer {
    private let smc: SMC
    private let keys: [FourCC]

    init(smc: SMC) throws {
        self.smc = smc
        var found: [FourCC] = []
        for i in 0..<(try smc.keyCount()) {
            guard let key = try? smc.key(at: i),
                  key.description.hasPrefix("T"),
                  let info = try? smc.keyInfo(key),
                  ["flt ", "sp78"].contains(info.type.description),
                  let v = try? smc.readNumber(key), v > 1, v < 130
            else { continue }
            found.append(key)
        }
        keys = found
    }

    func read() -> [Sensor] {
        keys.compactMap { key in
            guard let v = try? smc.readNumber(key), v > 1, v < 130 else { return nil }
            return Sensor(key: key.description, group: Thermometer.group(for: key.description), celsius: v)
        }
    }

    /// Hottest CPU sensor, or hottest overall if none is tagged CPU.
    static func cpu(_ sensors: [Sensor]) -> Sensor? {
        sensors.filter { $0.group == "CPU" }.max { $0.celsius < $1.celsius } ?? hottest(sensors)
    }

    static func hottest(_ sensors: [Sensor]) -> Sensor? {
        sensors.max { $0.celsius < $1.celsius }
    }

    private static func group(for key: String) -> String {
        switch key.prefix(2) {
        case "Tp", "TC", "Tc": return "CPU"
        case "Tg", "TG": return "GPU"
        case "TB", "Tb": return "Battery"
        case "Ta", "TA": return "Ambient"
        case "TH", "Th": return "Storage"
        case "TM", "Tm": return "Memory"
        case "Ts", "TS": return "Skin"
        case "TW", "Tw": return "Wireless"
        default: return "Other"
        }
    }
}
