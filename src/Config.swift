import Foundation

/// A binding may be written as a bare string ("up") or as an object with
/// per-gesture actions ({"tap":"up","double":"cmd+up","repeat":true}).
struct ButtonBinding: Decodable {
    var tap: String?
    var double: String?
    var triple: String?
    var hold: String?
    var hold2: String?
    /// Held down for exactly as long as the physical button is held. This is
    /// what Wispr push-to-talk needs, and it bypasses tap/hold entirely.
    var whileHeld: String?
    var autoRepeat: Bool?
    /// Played when this button's action fires (not on every auto-repeat).
    var sound: String?

    enum CodingKeys: String, CodingKey {
        case tap, double, triple, hold, hold2, whileHeld, sound
        case autoRepeat = "repeat"
    }

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self.tap = s
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tap        = try c.decodeIfPresent(String.self, forKey: .tap)
        double     = try c.decodeIfPresent(String.self, forKey: .double)
        triple     = try c.decodeIfPresent(String.self, forKey: .triple)
        hold       = try c.decodeIfPresent(String.self, forKey: .hold)
        hold2      = try c.decodeIfPresent(String.self, forKey: .hold2)
        whileHeld  = try c.decodeIfPresent(String.self, forKey: .whileHeld)
        autoRepeat = try c.decodeIfPresent(Bool.self,   forKey: .autoRepeat)
        sound      = try c.decodeIfPresent(String.self, forKey: .sound)
    }

    /// Whether resolving a tap must wait to see if another tap follows.
    var needsMultiTapWait: Bool { double != nil || triple != nil }
    var maxTaps: Int { triple != nil ? 3 : (double != nil ? 2 : 1) }

    func action(forTaps n: Int) -> String? {
        switch n {
        case 1: return tap
        case 2: return double ?? tap
        default: return triple ?? double ?? tap
        }
    }
}

struct Layer: Decodable {
    var name: String
    /// Buttons this layer leaves undefined fall back to layer 0. Set false to
    /// make the layer fully self-contained.
    var fallthroughToBase: Bool?
    /// Leader layers are entered deliberately, never by cycling through layers,
    /// so "layer:next" steps over them.
    var skipInCycle: Bool?
    var bindings: [String: ButtonBinding]
}

struct Settings: Decodable {
    var doubleTapWindowMs: Int?
    var holdThresholdMs: Int?
    var hold2ThresholdMs: Int?
    var repeatDelayMs: Int?
    var repeatIntervalMs: Int?
    var layerChangeSound: Bool?
    /// Safety net: never hold a synthetic key longer than this, so a crash or a
    /// dropped Bluetooth packet can't wedge a modifier down forever.
    var maxHeldKeySeconds: Double?
    /// How long a one-shot (leader) layer stays armed waiting for the next press.
    var oneShotTimeoutMs: Int?
    /// System sound names (see /System/Library/Sounds), or "none".
    var leaderArmedSound: String?
    var leaderExpiredSound: String?
    var layerSwitchSound: String?

    var doubleTapWindow: TimeInterval { Double(doubleTapWindowMs ?? 280) / 1000 }
    var holdThreshold:   TimeInterval { Double(holdThresholdMs ?? 350) / 1000 }
    var hold2Threshold:  TimeInterval { Double(hold2ThresholdMs ?? 900) / 1000 }
    var repeatDelay:     TimeInterval { Double(repeatDelayMs ?? 350) / 1000 }
    var repeatInterval:  TimeInterval { Double(repeatIntervalMs ?? 60) / 1000 }
    var soundOnLayer:    Bool         { layerChangeSound ?? true }
    var maxHeldKey:      TimeInterval { maxHeldKeySeconds ?? 120 }
    var oneShotTimeout:  TimeInterval { Double(oneShotTimeoutMs ?? 1500) / 1000 }
    var armedSound:      String       { leaderArmedSound ?? "Tink" }
    var expiredSound:    String       { leaderExpiredSound ?? "Purr" }
    var switchSound:     String       { layerSwitchSound ?? "Morse" }
}

struct Config: Decodable {
    var settings: Settings?
    var layers: [Layer]

    var s: Settings { settings ?? Settings() }

    static let path = NSString(string: "~/.config/siriremote/config.jsonc").expandingTildeInPath

    /// Strips // and /* */ comments so the config can be commented JSONC.
    static func stripComments(_ src: String) -> String {
        var out = "", inString = false, escaped = false
        var i = src.startIndex
        while i < src.endIndex {
            let c = src[i]
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i = src.index(after: i); continue
            }
            if c == "\"" { inString = true; out.append(c); i = src.index(after: i); continue }
            if c == "/", src.index(after: i) < src.endIndex {
                let n = src[src.index(after: i)]
                if n == "/" {
                    while i < src.endIndex, src[i] != "\n" { i = src.index(after: i) }
                    continue
                }
                if n == "*" {
                    i = src.index(i, offsetBy: 2)
                    while i < src.endIndex {
                        if src[i] == "*", src.index(after: i) < src.endIndex,
                           src[src.index(after: i)] == "/" { i = src.index(i, offsetBy: 2); break }
                        i = src.index(after: i)
                    }
                    continue
                }
            }
            out.append(c)
            i = src.index(after: i)
        }
        return out
    }

    static func load() throws -> Config {
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try defaultConfig.write(toFile: path, atomically: true, encoding: .utf8)
            FileHandle.standardError.write("wrote default config to \(path)\n".data(using: .utf8)!)
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let data = Data(stripComments(text).utf8)
        return try JSONDecoder().decode(Config.self, from: data)
    }
}
