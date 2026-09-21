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

import AppKit

/// One pickable sound. `id` is what goes in the config:
///   "Tink"                               — an alert sound (/System/Library/Sounds)
///   "ui:accessibility/Sticky Keys OFF.aif" — a system UI sound, by relative path
///   "user:Beep.aiff"                     — a file the user dropped in ~/Library/Sounds
struct SoundOption: Hashable {
    let id: String
    let name: String
    let category: String
    let path: String
    let duration: Double
}

enum Sounds {
    private static let alertDir = "/System/Library/Sounds"
    private static let uiDir =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds"
    private static let userDir = NSString(string: "~/Library/Sounds").expandingTildeInPath
    private static let exts: Set<String> = ["aif", "aiff", "caf", "wav", "mp3", "m4a"]

    /// Folder name -> heading shown in the picker.
    private static let uiCategories: [(dir: String, title: String)] = [
        ("accessibility", "辅助功能"), ("system", "系统"), ("siri", "Siri"),
        ("telephony", "电话按键"), ("dock", "Dock"), ("ink", "手写"),
        ("finder", "Finder"), ("facetime", "FaceTime"),
    ]

    /// UI sounds longer than this are tones and jingles, not feedback cues.
    private static let maxUIDuration = 1.0

    static let groups: [(title: String, options: [SoundOption])] = {
        var out: [(String, [SoundOption])] = []

        let alerts = files(in: alertDir).map { f -> SoundOption in
            let name = (f as NSString).deletingPathExtension
            let path = "\(alertDir)/\(f)"
            return SoundOption(id: name, name: name, category: "提醒音效",
                               path: path, duration: duration(path))
        }
        out.append(("提醒音效", alerts.sorted { $0.name < $1.name }))

        for (dir, title) in uiCategories {
            let opts = files(in: "\(uiDir)/\(dir)").compactMap { f -> SoundOption? in
                let path = "\(uiDir)/\(dir)/\(f)"
                let d = duration(path)
                guard d > 0, d <= maxUIDuration else { return nil }
                return SoundOption(id: "ui:\(dir)/\(f)",
                                   name: (f as NSString).deletingPathExtension,
                                   category: title, path: path, duration: d)
            }
            if !opts.isEmpty { out.append((title, opts.sorted { $0.duration < $1.duration })) }
        }

        let mine = files(in: userDir).map { f -> SoundOption in
            let path = "\(userDir)/\(f)"
            return SoundOption(id: "user:\(f)", name: (f as NSString).deletingPathExtension,
                               category: "我的音效", path: path, duration: duration(path))
        }
        if !mine.isEmpty { out.append(("我的音效", mine.sorted { $0.name < $1.name })) }
        return out
    }()

    static func option(_ id: String) -> SoundOption? {
        for g in groups { if let o = g.options.first(where: { $0.id == id }) { return o } }
        return nil
    }

    /// "辅助功能 › Sticky Keys OFF" — for showing the current choice.
    static func label(_ id: String) -> String {
        if id == "none" { return "无" }
        guard let o = option(id) else { return id }
        return o.category == "提醒音效" ? o.name : "\(o.category) › \(o.name)"
    }

    private static func files(in dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    private static func duration(_ path: String) -> Double {
        NSSound(contentsOfFile: path, byReference: true)?.duration ?? 0
    }

    /// One instance per file, so a replay can stop and restart it.
    private static var cache: [String: NSSound] = [:]

    static func play(_ id: String) {
        guard id != "none" else { return }
        let path = option(id)?.path ?? "\(alertDir)/\(id).aiff"
        let sound: NSSound
        if let cached = cache[path] { sound = cached }
        else {
            guard let fresh = NSSound(contentsOfFile: path, byReference: true) else { return }
            cache[path] = fresh
            sound = fresh
        }
        // play() on an instance that's still playing is silently ignored, so a
        // quick second leader press used to make no sound. Restart instead.
        sound.stop()
        sound.play()
    }
}
