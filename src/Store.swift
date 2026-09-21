import Foundation
import SwiftUI

// MARK: - Writing config back out
//
// The file stays JSONC-readable for hand editing, but the GUI rewrites it as
// plain JSON, so comments in a hand-edited file are lost once you save here.

extension ButtonBinding: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(tap, forKey: .tap)
        try c.encodeIfPresent(double, forKey: .double)
        try c.encodeIfPresent(triple, forKey: .triple)
        try c.encodeIfPresent(hold, forKey: .hold)
        try c.encodeIfPresent(hold2, forKey: .hold2)
        try c.encodeIfPresent(whileHeld, forKey: .whileHeld)
        try c.encodeIfPresent(autoRepeat, forKey: .autoRepeat)
        try c.encodeIfPresent(sound, forKey: .sound)
    }

    init() {}

    var isEmpty: Bool {
        tap == nil && double == nil && triple == nil
            && hold == nil && hold2 == nil && whileHeld == nil
    }

    /// One-line summary for the button list.
    var summary: String {
        if let w = whileHeld { return "hold: \(Action.parse(w).label)" }
        var parts: [String] = []
        if let t = tap    { parts.append(Action.parse(t).label) }
        if let d = double { parts.append("×2 \(Action.parse(d).label)") }
        if let t = triple { parts.append("×3 \(Action.parse(t).label)") }
        if let h = hold   { parts.append("⏱ \(Action.parse(h).label)") }
        return parts.isEmpty ? "—" : parts.joined(separator: "  ·  ")
    }
}

extension Layer: Encodable {
    enum LKeys: String, CodingKey { case name, fallthroughToBase, skipInCycle, bindings }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: LKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(fallthroughToBase, forKey: .fallthroughToBase)
        try c.encodeIfPresent(skipInCycle, forKey: .skipInCycle)
        try c.encode(bindings.filter { !$0.value.isEmpty }, forKey: .bindings)
    }
}

extension Settings: Encodable {
    enum SKeys: String, CodingKey {
        case doubleTapWindowMs, holdThresholdMs, hold2ThresholdMs
        case repeatDelayMs, repeatIntervalMs, layerChangeSound, maxHeldKeySeconds
        case oneShotTimeoutMs, leaderArmedSound, leaderExpiredSound, layerSwitchSound
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: SKeys.self)
        try c.encodeIfPresent(doubleTapWindowMs, forKey: .doubleTapWindowMs)
        try c.encodeIfPresent(holdThresholdMs, forKey: .holdThresholdMs)
        try c.encodeIfPresent(hold2ThresholdMs, forKey: .hold2ThresholdMs)
        try c.encodeIfPresent(repeatDelayMs, forKey: .repeatDelayMs)
        try c.encodeIfPresent(repeatIntervalMs, forKey: .repeatIntervalMs)
        try c.encodeIfPresent(layerChangeSound, forKey: .layerChangeSound)
        try c.encodeIfPresent(maxHeldKeySeconds, forKey: .maxHeldKeySeconds)
        try c.encodeIfPresent(oneShotTimeoutMs, forKey: .oneShotTimeoutMs)
        try c.encodeIfPresent(leaderArmedSound, forKey: .leaderArmedSound)
        try c.encodeIfPresent(leaderExpiredSound, forKey: .leaderExpiredSound)
        try c.encodeIfPresent(layerSwitchSound, forKey: .layerSwitchSound)
    }
}

extension Config: Encodable {
    enum CKeys: String, CodingKey { case settings, layers }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CKeys.self)
        try c.encodeIfPresent(settings, forKey: .settings)
        try c.encode(layers, forKey: .layers)
    }
}

// MARK: - What a gesture does, as the UI thinks of it

enum Action: Equatable {
    case none
    case key(String)
    case layerNext
    case layerPrev
    case layerSet(String)
    case layerMomentary(String)
    case layerOneShot(String)
    case target(String)

    static func parse(_ s: String?) -> Action {
        guard let s, !s.isEmpty, s != "none" else { return .none }
        if s == "layer:next" { return .layerNext }
        if s == "layer:prev" { return .layerPrev }
        if s.hasPrefix("layer:") { return .layerSet(String(s.dropFirst(6))) }
        if s.hasPrefix("layerMomentary:") { return .layerMomentary(String(s.dropFirst(15))) }
        if s.hasPrefix("layerOneShot:") { return .layerOneShot(String(s.dropFirst(13))) }
        if s.hasPrefix("target:") { return .target(String(s.dropFirst(7))) }
        return .key(s)
    }

    var encoded: String? {
        switch self {
        case .none: return nil
        case .key(let k): return k.isEmpty ? nil : k
        case .layerNext: return "layer:next"
        case .layerPrev: return "layer:prev"
        case .layerSet(let l): return "layer:\(l)"
        case .layerMomentary(let l): return "layerMomentary:\(l)"
        case .layerOneShot(let l): return "layerOneShot:\(l)"
        case .target(let t): return "target:\(t)"
        }
    }

    /// Pretty form: "⌃⇥" rather than "ctrl+tab".
    var label: String {
        switch self {
        case .none: return "—"
        case .key(let k): return KeyStroke.prettify(k)
        case .layerNext: return "下一层"
        case .layerPrev: return "上一层"
        case .layerSet(let l): return "切到 \(l)"
        case .layerMomentary(let l): return "按住 = \(l)"
        case .layerOneShot(let l): return "leader → \(l)"
        case .target(let t):
            switch t {
            case "next":  return "下一台电脑"
            case "prev":  return "上一台电脑"
            case "local": return "切回本机"
            default:      return "切到 \(t)"
            }
        }
    }

    var kindIndex: Int {
        switch self {
        case .none: return 0
        case .key: return 1
        case .layerNext: return 2
        case .layerPrev: return 3
        case .layerSet: return 4
        case .layerMomentary: return 5
        case .layerOneShot: return 6
        case .target: return 7
        }
    }
}

// MARK: - Store

final class ConfigStore: ObservableObject {
    @Published var config: Config
    @Published var saveError: String?
    /// When we last wrote the file ourselves, so a watcher callback triggered by
    /// our own save doesn't reload over what the user is editing.
    private(set) var lastSave = Date.distantPast

    init(config: Config) { self.config = config }

    func binding(layer li: Int, button b: Button) -> ButtonBinding {
        guard li < config.layers.count else { return ButtonBinding() }
        return config.layers[li].bindings[b.rawValue] ?? ButtonBinding()
    }

    func setBinding(_ v: ButtonBinding, layer li: Int, button b: Button) {
        guard li < config.layers.count else { return }
        if v.isEmpty { config.layers[li].bindings.removeValue(forKey: b.rawValue) }
        else { config.layers[li].bindings[b.rawValue] = v }
        save()
    }

    func addLayer() {
        config.layers.append(Layer(name: "layer\(config.layers.count)",
                                   fallthroughToBase: true, bindings: [:]))
        save()
    }

    func removeLayer(_ i: Int) {
        guard config.layers.count > 1, i < config.layers.count else { return }
        config.layers.remove(at: i)
        save()
    }

    func save() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try enc.encode(config)
            lastSave = Date()
            try data.write(to: URL(fileURLWithPath: Config.path), options: .atomic)
            saveError = nil
        } catch {
            saveError = "\(error)"
            Log.write("save failed: \(error)")
        }
    }
}
