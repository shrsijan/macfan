import Foundation

/// Raw-mode keyboard input and screen clearing. Falls back to plain output when piped.
final class Terminal {
    enum Key {
        case up, down, left, right
        case char(Character)
    }

    let isInteractive: Bool
    private var original = termios()

    init() {
        isInteractive = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        guard isInteractive else { return }
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        write("\u{1B}[?25l")
    }

    func restore() {
        guard isInteractive else { return }
        write("\u{1B}[?25h\n")
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
    }

    /// Returns nil when `timeout` elapses with no key.
    func readKey(timeout: Double) -> Key? {
        guard isInteractive else {
            usleep(useconds_t(timeout * 1_000_000))
            return nil
        }
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: 8)
        let n = read(STDIN_FILENO, &buf, buf.count)
        guard n > 0 else { return nil }
        if n >= 3, buf[0] == 0x1B, buf[1] == 0x5B {
            switch buf[2] {
            case 0x41: return .up
            case 0x42: return .down
            case 0x43: return .right
            case 0x44: return .left
            default: return nil
            }
        }
        return String(decoding: buf[0..<n], as: UTF8.self).first.map(Key.char)
    }

    func clear() {
        guard isInteractive else { return }
        write("\u{1B}[H\u{1B}[2J")
    }

    func write(_ s: String) {
        FileHandle.standardOutput.write(s.data(using: .utf8)!)
    }
}
