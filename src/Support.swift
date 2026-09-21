import Foundation

/// Logs to stderr and to ~/Library/Logs/siriremoted.log, so the daemon stays
/// debuggable once it runs headless as a login agent.
enum Log {
    static let fileURL = URL(fileURLWithPath:
        NSString(string: "~/Library/Logs/siriremoted.log").expandingTildeInPath)
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func write(_ s: String) {
        let line = "[\(fmt.string(from: Date()))] \(s)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        if let h = try? FileHandle(forWritingTo: fileURL) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}

/// Signal sources must outlive the loop that creates them.
var signalSources: [DispatchSourceSignal] = []

/// Watches the config file and fires on change. Editors write by replacing the
/// file, which kills a plain vnode watch, so re-arm after every event.
final class ConfigWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() { arm() }

    private func arm() {
        source?.cancel()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm() }
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            self.debounce?.cancel()
            let work = DispatchWorkItem { self.onChange() }
            self.debounce = work
            // Editors often write in several bursts; coalesce them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            self.arm()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }
}
