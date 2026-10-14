import Foundation

let version = "1.0.0"

let usage = """
usage: macfan [options]                live dashboard; sudo enables the controls
       macfan set <rpm|N%> [--fan N]   force a speed and exit        (needs sudo)
       macfan default [--fan N]        give control back to macOS    (needs sudo)
       macfan status                   print fans and temperatures once
       macfan version

options:
  --interval <sec>   refresh rate (default 1)
  --step <rpm>       ↑/↓ increment (default 100; ←/→ is 5× that)

keys in the dashboard:
  ↑ ↓   adjust target rpm        ← →   adjust in big steps
  d     back to system default   q     quit (restores system default)
"""

// MARK: Arguments

struct Args {
    private(set) var positional: [String] = []
    private var options: [String: String] = [:]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    options[name] = argv[i + 1]
                    i += 1
                } else {
                    options[name] = ""
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func flag(_ name: String) -> Bool { options[name] != nil }

    func double(_ name: String, default value: Double) throws -> Double {
        guard let raw = options[name] else { return value }
        guard let v = Double(raw), v > 0 else { throw MacFanError("--\(name) expects a positive number") }
        return v
    }

    func int(_ name: String) throws -> Int? {
        guard let raw = options[name] else { return nil }
        guard let v = Int(raw) else { throw MacFanError("--\(name) expects an integer") }
        return v
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("macfan: \(message)\n".data(using: .utf8)!)
    exit(1)
}

/// Accepts "3000" (rpm) or "60%" (of the fan's range).
func parseSpeed(_ raw: String, for fan: Fan) throws -> Double {
    if raw.hasSuffix("%") {
        guard let pct = Double(raw.dropLast()) else { throw MacFanError("invalid percentage '\(raw)'") }
        return fan.rpm(forPercent: pct)
    }
    guard let rpm = Double(raw), rpm >= 0 else { throw MacFanError("invalid speed '\(raw)' (use rpm or N%)") }
    return rpm
}

// MARK: Rendering

let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func bar(_ fraction: Double, width: Int = 24) -> String {
    let filled = Int((max(0, min(1, fraction)) * Double(width)).rounded())
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

func temperatureLine(_ sensors: [Sensor]) -> String {
    var parts: [String] = []
    if let cpu = Thermometer.cpu(sensors) { parts.append(String(format: "CPU %.1f°C", cpu.celsius)) }
    if let gpu = sensors.filter({ $0.group == "GPU" }).max(by: { $0.celsius < $1.celsius }) {
        parts.append(String(format: "GPU %.1f°C", gpu.celsius))
    }
    if let hot = Thermometer.hottest(sensors) { parts.append(String(format: "Hottest %.1f°C (%@)", hot.celsius, hot.key)) }
    return parts.joined(separator: "   ")
}

func dashboard(fans: [Fan], sensors: [Sensor], target: Double?, canControl: Bool, step: Double, message: String?) -> String {
    var out: [String] = []
    out.append("macfan" + String(repeating: " ", count: 56) + clock.string(from: Date()))
    out.append("")
    for f in fans {
        let mode = f.mode == .manual ? "manual" : "default"
        out.append(String(format: " %@ %5.0f rpm  %@  target %5.0f  %@",
                          f.label.padding(toLength: 6, withPad: " ", startingAt: 0),
                          f.actual, bar(f.actual / max(1, f.maximum)), f.target, mode))
    }
    out.append("")
    out.append(" " + temperatureLine(sensors))
    out.append("")
    if canControl {
        let targetText = target.map { String(format: "target %.0f rpm", $0) } ?? "system default"
        out.append(String(format: " ↑↓ ±%.0f   ←→ ±%.0f   d default   q quit (restores default)        %@", step, step * 5, targetText))
    } else {
        out.append(" read-only — run with sudo to control the fans   q quit")
    }
    if let message { out.append(" " + message) }
    return out.joined(separator: "\n") + "\n"
}

/// Current state plus how to undo it; printed by every one-off command.
func printStatus(fans: FanController, smc: SMC) throws {
    let current = try fans.fans()
    for f in current {
        print(String(format: "%@ %5.0f rpm  target %5.0f  range %4.0f–%4.0f  %@",
                     f.label, f.actual, f.target, f.minimum, f.maximum, f.mode == .manual ? "manual" : "default"))
    }
    print(temperatureLine(try Thermometer(smc: smc).read()))
    print()
    if current.contains(where: { $0.mode == .manual }) {
        print("fans are forced (speed may take a few seconds to settle)")
        print("to stop:  sudo macfan default     live view:  sudo macfan")
    } else if try !fans.isReleased() {
        print("fans are not forced, but the firmware unlock flag is still set")
        print("to fully hand back control:  sudo macfan default")
    } else {
        print("macOS is managing the fans (system default)")
        print("to force a speed:  sudo macfan set <rpm|N%>   (e.g. 100% = max)")
    }
}

/// One line per tick when output is piped.
func logLine(fans: [Fan], sensors: [Sensor]) -> String {
    var s = clock.string(from: Date())
    for f in fans { s += String(format: "  fan%d %4.0f", f.index, f.actual) }
    if let cpu = Thermometer.cpu(sensors) { s += String(format: "  cpu %.1f", cpu.celsius) }
    if let gpu = sensors.filter({ $0.group == "GPU" }).max(by: { $0.celsius < $1.celsius }) {
        s += String(format: "  gpu %.1f", gpu.celsius)
    }
    return s
}

// MARK: Dashboard

var stopRequested: sig_atomic_t = 0
signal(SIGINT) { _ in stopRequested = 1 }
signal(SIGTERM) { _ in stopRequested = 1 }

func runDashboard(fans: FanController, thermo: Thermometer, interval: Double, step: Double) throws {
    let term = Terminal()
    let canControl = getuid() == 0
    var target: Double? = nil
    var message: String? = nil
    var restoreOnExit = false
    defer {
        if restoreOnExit { try? fans.restoreDefault() }
        term.restore()
    }

    // Adopt a speed set earlier with `macfan set`; quitting releases whatever is held.
    if let forced = try fans.fans().first(where: { $0.mode == .manual }) {
        target = forced.target
    }
    if canControl, try !fans.isReleased() {
        restoreOnExit = true
    }

    func draw(_ note: String? = nil) throws {
        let current = try fans.fans()
        let sensors = thermo.read()
        term.clear()
        if term.isInteractive {
            term.write(dashboard(fans: current, sensors: sensors, target: target,
                                 canControl: canControl, step: step, message: note ?? message))
        } else {
            term.write(logLine(fans: current, sensors: sensors) + "\n")
        }
    }

    func apply(_ rpm: Double) throws {
        let all = try fans.fans()
        let lo = all.map(\.minimum).min() ?? 0
        let hi = all.map(\.maximum).max() ?? 0
        let clamped = max(lo, min(hi, rpm))
        if target == nil { try draw("unlocking fan control…") }
        for f in all { try fans.setSpeed(fan: f.index, rpm: clamped) }
        target = clamped
        restoreOnExit = true
        message = nil
    }

    while stopRequested == 0 {
        try draw()
        guard let key = term.readKey(timeout: interval) else { continue }

        switch key {
        case .char("q"), .char("Q"):
            return
        case .up, .down, .left, .right, .char("+"), .char("-"), .char("="):
            guard canControl else { message = "run with sudo to change fan speed"; continue }
            let delta: Double
            switch key {
            case .up, .char("+"), .char("="): delta = step
            case .down, .char("-"): delta = -step
            case .right: delta = step * 5
            default: delta = -step * 5
            }
            do {
                let base = try target ?? (fans.fans().map(\.actual).max() ?? 0)
                try apply(base + delta)
            } catch { message = "\(error)" }
        case .char("d"), .char("D"):
            guard canControl else { message = "run with sudo to change fan speed"; continue }
            do {
                try fans.restoreDefault()
                target = nil
                restoreOnExit = false
                message = nil
            } catch { message = "\(error)" }
        default:
            continue
        }
    }
}

// MARK: Entry

func run() throws {
    let argv = Array(CommandLine.arguments.dropFirst())
    let isCommand = argv.first.map { !$0.hasPrefix("--") } ?? false
    let command = isCommand ? argv[0] : "dashboard"
    let args = Args(isCommand ? Array(argv.dropFirst()) : argv)

    if command == "help" || args.flag("help") || args.flag("h") {
        print(usage)
        return
    }
    if command == "version" || args.flag("version") {
        print("macfan \(version)")
        return
    }

    let smc = try SMC()
    let fans = try FanController(smc: smc)

    func targets() throws -> [Int] {
        if let i = try args.int("fan") { return [i] }
        return Array(0..<fans.count)
    }

    switch command {
    case "dashboard":
        try runDashboard(
            fans: fans,
            thermo: try Thermometer(smc: smc),
            interval: try args.double("interval", default: 1),
            step: try args.double("step", default: 100)
        )

    case "status":
        try printStatus(fans: fans, smc: smc)

    case "set":
        guard let raw = args.positional.first else { throw MacFanError("set requires a speed (rpm or N%)") }
        for i in try targets() {
            let fan = try fans.fan(at: i)
            let requested = try parseSpeed(raw, for: fan)
            let applied = try fans.setSpeed(fan: i, rpm: requested)
            let note = applied == requested.rounded() ? "" :
                String(format: "  (clamped to %.0f–%.0f)", fan.minimum, fan.maximum)
            print(String(format: "%@ -> %.0f rpm%@", fan.label, applied, note))
        }
        print()
        try printStatus(fans: fans, smc: smc)

    case "default", "auto":
        let selected = try targets()
        try fans.restoreDefault(fans: selected)
        for i in selected { print("\(try fans.fan(at: i).label) -> system default") }
        print()
        try printStatus(fans: fans, smc: smc)

    default:
        throw MacFanError("unknown command '\(command)'\n\n\(usage)")
    }
}

do {
    try run()
} catch {
    fail("\(error)")
}
