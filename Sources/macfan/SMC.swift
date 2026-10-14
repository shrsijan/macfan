import Foundation
import IOKit

// User-space client for the AppleSMC IOKit service. Reads work for any user,
// writes need root.

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private let zeroBytes: SMCBytes = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
)

// Must match the 80-byte C struct AppleSMC expects; size is asserted in SMC.init.
struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = zeroBytes
}

/// Four-character key or type code such as "F0Ac" or "flt ".
struct FourCC: Hashable, CustomStringConvertible {
    let raw: UInt32

    init(_ code: String) {
        precondition(code.utf8.count == 4, "FourCC must be exactly 4 bytes")
        raw = code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    init(raw: UInt32) { self.raw = raw }

    var description: String {
        let b = [24, 16, 8, 0].map { UInt8((raw >> UInt32($0)) & 0xFF) }
        return String(decoding: b, as: UTF8.self)
    }
}

struct SMCKeyInfo {
    let size: Int
    let type: FourCC
}

enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case notPrivileged
    case keyNotFound(FourCC)
    case smcResult(UInt8, FourCC)
    case unsupportedType(FourCC, FourCC)
    case badLayout(Int)

    var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let r): return "could not open AppleSMC (0x\(String(r, radix: 16)))"
        case .callFailed(let r): return "SMC call failed (0x\(String(r, radix: 16)))"
        case .notPrivileged: return "writing to the SMC requires root; re-run with sudo"
        case .keyNotFound(let k): return "SMC key \(k) not found"
        case .smcResult(let code, let k): return "SMC returned 0x\(String(code, radix: 16)) for key \(k)"
        case .unsupportedType(let t, let k): return "unsupported SMC data type '\(t)' for key \(k)"
        case .badLayout(let size): return "SMCParamStruct has unexpected size \(size), expected 80"
        }
    }
}

final class SMC {
    private enum Command: UInt8 {
        case readKey = 5
        case writeKey = 6
        case keyFromIndex = 8
        case keyInfo = 9
    }

    private static let selector: UInt32 = 2  // kSMCHandleYPCEvent
    private var connection: io_connect_t = 0
    private var infoCache: [FourCC: SMCKeyInfo] = [:]

    init() throws {
        let size = MemoryLayout<SMCParamStruct>.stride
        guard size == 80 else { throw SMCError.badLayout(size) }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        let r = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard r == kIOReturnSuccess else { throw SMCError.openFailed(r) }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: Raw access

    private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(
            connection, SMC.selector,
            &input, MemoryLayout<SMCParamStruct>.stride,
            &output, &outputSize
        )
        if r == kIOReturnNotPrivileged { throw SMCError.notPrivileged }
        guard r == kIOReturnSuccess else { throw SMCError.callFailed(r) }
        return output
    }

    func keyInfo(_ key: FourCC) throws -> SMCKeyInfo {
        if let cached = infoCache[key] { return cached }
        var input = SMCParamStruct()
        input.key = key.raw
        input.data8 = Command.keyInfo.rawValue
        let out = try call(input)
        try check(out, key)
        let info = SMCKeyInfo(size: Int(out.keyInfo.dataSize), type: FourCC(raw: out.keyInfo.dataType))
        infoCache[key] = info
        return info
    }

    func hasKey(_ key: FourCC) -> Bool {
        (try? keyInfo(key)) != nil
    }

    func readBytes(_ key: FourCC) throws -> (SMCKeyInfo, [UInt8]) {
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = key.raw
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = Command.readKey.rawValue
        let out = try call(input)
        try check(out, key)
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(info.size)) }
        return (info, bytes)
    }

    func writeBytes(_ key: FourCC, _ bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        precondition(bytes.count == info.size, "payload size mismatch for \(key)")
        var input = SMCParamStruct()
        input.key = key.raw
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = Command.writeKey.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
        }
        let out = try call(input)
        try check(out, key)
    }

    func keyCount() throws -> Int {
        Int(try readNumber(FourCC("#KEY")))
    }

    func key(at index: Int) throws -> FourCC {
        var input = SMCParamStruct()
        input.data8 = Command.keyFromIndex.rawValue
        input.data32 = UInt32(index)
        let out = try call(input)
        guard out.result == 0 else { throw SMCError.smcResult(out.result, FourCC(raw: 0)) }
        return FourCC(raw: out.key)
    }

    private func check(_ out: SMCParamStruct, _ key: FourCC) throws {
        switch out.result {
        case 0: return
        case 0x84: throw SMCError.keyNotFound(key)
        default: throw SMCError.smcResult(out.result, key)
        }
    }

    // MARK: Typed access

    func readNumber(_ key: FourCC) throws -> Double {
        let (info, b) = try readBytes(key)
        func be16() -> UInt16 { UInt16(b[0]) << 8 | UInt16(b[1]) }
        func be32() -> UInt32 { UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]) }
        switch info.type.description {
        case "flt ":
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2": return Double(be16() >> 2)
        case "fp88": return Double(be16()) / 256
        case "sp78": return Double(Int16(bitPattern: be16())) / 256
        case "ui8 ": return Double(b[0])
        case "ui16": return Double(be16())
        case "ui32": return Double(be32())
        case "si8 ": return Double(Int8(bitPattern: b[0]))
        case "si16": return Double(Int16(bitPattern: be16()))
        default: throw SMCError.unsupportedType(info.type, key)
        }
    }

    func writeNumber(_ key: FourCC, _ value: Double) throws {
        let info = try keyInfo(key)
        let bytes: [UInt8]
        switch info.type.description {
        case "flt ":
            let bits = Float(value).bitPattern
            bytes = [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24 & 0xFF)]
        case "fpe2":
            let v = UInt16(max(0, min(16383, value.rounded()))) << 2
            bytes = [UInt8(v >> 8), UInt8(v & 0xFF)]
        case "ui8 ":
            bytes = [UInt8(max(0, min(255, value.rounded())))]
        case "ui16":
            let v = UInt16(max(0, min(65535, value.rounded())))
            bytes = [UInt8(v >> 8), UInt8(v & 0xFF)]
        case "ui32":
            let v = UInt32(max(0, min(4_294_967_295, value.rounded())))
            bytes = [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        default:
            throw SMCError.unsupportedType(info.type, key)
        }
        try writeBytes(key, bytes)
    }
}
