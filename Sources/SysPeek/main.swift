import Foundation
import Darwin

struct Config {
    enum Output {
        case tui
        case text
        case json
    }

    var output: Output = .tui
    var once = false
    var intervalMs = 1000
    var top = 15
    var sort: SortKey = .cpu
    var showIo = true
    var color = isatty(STDOUT_FILENO) != 0
}

let usageText = """
syspeek - zero-dependency macOS system monitor in the terminal

USAGE
  syspeek [options]

MODES
  (default)     live TUI, redraws every interval
  --once        one text snapshot, for logs and pipes
  --json        NDJSON, one object per interval
  --once --json a single JSON object

OPTIONS
  -i, --interval <ms>   refresh interval            (default 1000, min 100)
  -n, --top <count>     process rows to rank        (default 15)
  -s, --sort <key>      cpu|mem                      (default cpu)
      --no-io           drop per-process disk R/W columns
      --no-color        disable ANSI colour
  -h, --help            this text

KEYS
  q quit   s toggle sort   up/down or j/k scroll the process list
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("syspeek: \(message)\n".data(using: .utf8)!)
    exit(2)
}

func parseConfig(_ args: [String]) -> Config {
    var c = Config()
    var index = 0
    while index < args.count {
        let arg = args[index]
        func intArg() -> Int {
            guard index + 1 < args.count, let value = Int(args[index + 1]) else {
                fail("\(arg) needs a number")
            }
            index += 1
            return value
        }
        switch arg {
        case "--once": c.once = true
        case "--json": c.output = .json
        case "--no-io": c.showIo = false
        case "--no-color": c.color = false
        case "-i", "--interval":
            let ms = intArg()
            guard ms >= 100 else { fail("--interval must be >= 100") }
            c.intervalMs = ms
        case "-n", "--top":
            let n = intArg()
            guard n >= 1 else { fail("--top must be >= 1") }
            c.top = n
        case "-s", "--sort":
            guard index + 1 < args.count, let key = SortKey(rawValue: args[index + 1]) else {
                fail("--sort takes cpu or mem")
            }
            index += 1
            c.sort = key
        case "-h", "--help":
            print(usageText)
            exit(0)
        default:
            fail("unknown argument \(arg); try --help")
        }
        index += 1
    }
    if c.once, c.output == .tui { c.output = .text }
    if c.output == .tui, isatty(STDOUT_FILENO) == 0 { c.output = .text }
    return c
}

final class Terminal {
    private var original = termios()
    private var raw = false

    // A SIGINT/SIGTERM default-terminates the process, so the defer in runTui never
    // runs and the user's terminal would stay in raw mode with the cursor hidden.
    nonisolated(unsafe) static var current: Terminal?

    enum Key {
        case quit, sort, up, down
    }

    // Non-blocking input is a poll() check before each read(): termios.c_cc has no
    // subscript in Swift (it imports as a fixed tuple), fcntl is unavailable
    // because it is variadic, and the FIONBIO macro cannot be imported either.
    func enterRawMode() {
        guard isatty(STDIN_FILENO) != 0 else { return }
        tcgetattr(STDIN_FILENO, &original)
        var mode = original
        mode.c_lflag &= ~UInt(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSADRAIN, &mode)
        raw = true
        Terminal.current = self
        installSignalHandlers()
        write("\u{1b}[?25l")
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig) { code in
                Terminal.current?.restore()
                exit(128 + code)
            }
        }
    }

    func restore() {
        guard raw else { return }
        tcsetattr(STDIN_FILENO, TCSADRAIN, &original)
        write("\u{1b}[0m\u{1b}[?25h")
        raw = false
        Terminal.current = nil
    }

    var size: (width: Int, height: Int) {
        var ws = winsize()
        if isatty(STDOUT_FILENO) != 0, ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (80, 24)
    }

    func write(_ s: String) {
        FileHandle.standardOutput.write(s.data(using: .utf8)!)
    }

    private func readable(timeoutMs: Int) -> Bool {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&pfd, 1, Int32(timeoutMs)) > 0
    }

    /// Arrows arrive as ESC [ <c>; a lone ESC with nothing behind it is treated as no key.
    func readKey() -> Key? {
        guard readable(timeoutMs: 0) else { return nil }
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
        if byte == 0x1b {
            guard readable(timeoutMs: 15) else { return nil }
            var tail: [UInt8] = [0, 0]
            let got = tail.withUnsafeMutableBufferPointer { read(STDIN_FILENO, $0.baseAddress, 2) }
            if got == 2, tail[0] == UInt8(ascii: "["), tail[1] == UInt8(ascii: "A") { return .up }
            if got == 2, tail[0] == UInt8(ascii: "["), tail[1] == UInt8(ascii: "B") { return .down }
            return nil
        }
        switch byte {
        case UInt8(ascii: "q"), 0x03: return .quit
        case UInt8(ascii: "s"): return .sort
        case UInt8(ascii: "k"): return .up
        case UInt8(ascii: "j"): return .down
        default: return nil
        }
    }
}

func nap(ms: Int) {
    var tv = timeval(tv_sec: ms / 1000, tv_usec: Int32((ms % 1000) * 1000))
    select(0, nil, nil, nil, &tv)
}

func runTui(_ config: Config, _ sampler: Sampler) {
    let terminal = Terminal()
    terminal.enterRawMode()
    defer { terminal.restore() }

    let renderer = Renderer(color: config.color)
    var sort = config.sort
    var scroll = 0
    var snapshot = sampler.sample(sort: sort, top: config.top)

    loop: while true {
        let size = terminal.size
        let options = ViewOptions(
            width: size.width,
            height: size.height,
            sort: sort,
            scroll: scroll,
            color: config.color,
            showIo: config.showIo
        )
        let body = renderer.lines(snapshot, options)
        let footer = renderer.footer(sort: sort, rows: body.count, width: size.width)
        terminal.write("\u{1b}[H\u{1b}[2J" + body.joined(separator: "\r\n") + "\r\n" + footer)

        var waited = 0
        while waited < config.intervalMs {
            guard let key = terminal.readKey() else {
                nap(ms: 20)
                waited += 20
                continue
            }
            switch key {
            case .quit:
                break loop
            case .sort:
                sort = sort == .cpu ? .mem : .cpu
                scroll = 0
            case .up:
                scroll = Swift.max(0, scroll - 1)
            case .down:
                scroll += 1
            }
            snapshot = sampler.sample(sort: sort, top: config.top)
        }
        snapshot = sampler.sample(sort: sort, top: config.top)
    }
    terminal.write("\r\n")
}

func emitJSON(_ snapshot: Snapshot, to encoder: JSONEncoder) {
    guard let data = try? encoder.encode(snapshot) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func execute(_ config: Config) {
    let sampler = Sampler()
    // Cumulative counters need two reads before any rate is meaningful.
    _ = sampler.sample(sort: config.sort, top: config.top)
    nap(ms: config.once ? Swift.min(500, config.intervalMs) : config.intervalMs)

    switch config.output {
    case .text:
        let snapshot = sampler.sample(sort: config.sort, top: config.top)
        let terminal = Terminal()
        let options = ViewOptions(
            width: terminal.size.width,
            height: 40,
            sort: config.sort,
            scroll: 0,
            color: config.color,
            showIo: config.showIo
        )
        print(Renderer(color: config.color).lines(snapshot, options).joined(separator: "\n"))
    case .json:
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        emitJSON(sampler.sample(sort: config.sort, top: config.top), to: encoder)
        if config.once { return }
        while true {
            nap(ms: config.intervalMs)
            emitJSON(sampler.sample(sort: config.sort, top: config.top), to: encoder)
        }
    case .tui:
        runTui(config, sampler)
    }
}

execute(parseConfig(Array(CommandLine.arguments.dropFirst())))
