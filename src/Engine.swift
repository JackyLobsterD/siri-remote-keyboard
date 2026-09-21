import Foundation
import AppKit

private final class ButtonState {
    var tapCount = 0
    var resolveTimer: Timer?
    var holdTimers: [Timer] = []
    var repeatTimer: Timer?
    var holdFired = false
    var heldKey: KeyStroke?
    var heldKeyGuard: Timer?
    var momentaryLayer: Int?

    func cancelTimers() {
        resolveTimer?.invalidate(); resolveTimer = nil
        holdTimers.forEach { $0.invalidate() }; holdTimers = []
        repeatTimer?.invalidate(); repeatTimer = nil
    }
}

final class Engine {
    private var config: Config
    private var layerIndex = 0
    private var states: [Button: ButtonState] = [:]

    init(config: Config) {
        self.config = config
        for b in Button.allCases { states[b] = ButtonState() }
    }

    func reload(_ c: Config) {
        releaseEverything()
        config = c
        if layerIndex >= c.layers.count { layerIndex = 0 }
        log("config reloaded — \(c.layers.count) layer(s), now on \"\(currentLayerName)\"")
    }

    var currentLayerName: String {
        let i = effectiveLayer
        return i < config.layers.count ? config.layers[i].name : "?"
    }

    private var effectiveLayer: Int {
        for b in Button.allCases {
            if let m = states[b]?.momentaryLayer { return m }
        }
        return layerIndex
    }

    private func binding(for b: Button) -> Binding? {
        let idx = effectiveLayer
        guard idx < config.layers.count else { return nil }
        let layer = config.layers[idx]
        if let bind = layer.bindings[b.rawValue] { return bind }
        if layer.fallthroughToBase ?? true, idx != 0, !config.layers.isEmpty {
            return config.layers[0].bindings[b.rawValue]
        }
        return nil
    }

    // MARK: - Input

    func handle(_ button: Button, pressed: Bool) {
        guard let st = states[button] else { return }
        guard let bind = binding(for: button) else { return }

        if let held = bind.whileHeld {
            pressed ? beginWhileHeld(button, st, held) : endWhileHeld(button, st)
            return
        }

        if pressed {
            st.holdFired = false
            scheduleHolds(button, st, bind)
            if bind.autoRepeat == true, let a = bind.tap { scheduleRepeat(st, a) }
        } else {
            st.cancelTimers()
            if st.holdFired { st.tapCount = 0; return }
            st.tapCount += 1
            if bind.needsMultiTapWait && st.tapCount < bind.maxTaps {
                st.resolveTimer = Timer.scheduledTimer(
                    withTimeInterval: config.s.doubleTapWindow, repeats: false) { [weak self] _ in
                    self?.resolveTaps(button, st, bind)
                }
            } else {
                resolveTaps(button, st, bind)
            }
        }
    }

    private func resolveTaps(_ button: Button, _ st: ButtonState, _ bind: Binding) {
        let n = st.tapCount
        st.tapCount = 0
        st.resolveTimer?.invalidate(); st.resolveTimer = nil
        guard n > 0, let action = bind.action(forTaps: n) else { return }
        perform(action, from: button, state: st)
    }

    private func scheduleHolds(_ button: Button, _ st: ButtonState, _ bind: Binding) {
        let stages: [(TimeInterval, String?)] = [
            (config.s.holdThreshold,  bind.hold),
            (config.s.hold2Threshold, bind.hold2),
        ]
        for (delay, action) in stages {
            guard let action else { continue }
            let t = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                st.holdFired = true
                st.tapCount = 0
                st.repeatTimer?.invalidate(); st.repeatTimer = nil
                self?.perform(action, from: button, state: st)
            }
            st.holdTimers.append(t)
        }
    }

    private func scheduleRepeat(_ st: ButtonState, _ action: String) {
        st.repeatTimer = Timer.scheduledTimer(
            withTimeInterval: config.s.repeatDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            st.repeatTimer = Timer.scheduledTimer(
                withTimeInterval: self.config.s.repeatInterval, repeats: true) { _ in
                if let k = KeyStroke.parse(action) { KeySynth.tap(k) }
            }
        }
    }

    // MARK: - whileHeld (push-to-talk)

    private func beginWhileHeld(_ button: Button, _ st: ButtonState, _ action: String) {
        if action.hasPrefix("layerMomentary:") {
            let spec = String(action.dropFirst("layerMomentary:".count))
            if let i = resolveLayer(spec) { st.momentaryLayer = i; announceLayer() }
            return
        }
        guard let k = KeyStroke.parse(action) else {
            log("whileHeld: cannot parse \"\(action)\""); return
        }
        if st.heldKey != nil { endWhileHeld(button, st) }
        st.heldKey = k
        KeySynth.down(k)
        // If the release event never arrives (Bluetooth drop, crash mid-hold) a
        // stuck modifier would wreck every keystroke that follows. Force it up.
        st.heldKeyGuard = Timer.scheduledTimer(
            withTimeInterval: config.s.maxHeldKey, repeats: false) { [weak self] _ in
            self?.log("safety: releasing stuck key on \(button.rawValue)")
            self?.endWhileHeld(button, st)
        }
    }

    private func endWhileHeld(_ button: Button, _ st: ButtonState) {
        st.heldKeyGuard?.invalidate(); st.heldKeyGuard = nil
        if let k = st.heldKey { KeySynth.up(k); st.heldKey = nil }
        if st.momentaryLayer != nil { st.momentaryLayer = nil; announceLayer() }
    }

    // MARK: - Actions

    private func perform(_ action: String, from button: Button, state st: ButtonState) {
        if action == "none" { return }

        if action.hasPrefix("layer:") {
            let spec = String(action.dropFirst("layer:".count))
            switch spec {
            case "next": layerIndex = (layerIndex + 1) % max(config.layers.count, 1)
            case "prev": layerIndex = (layerIndex - 1 + config.layers.count) % max(config.layers.count, 1)
            default:
                guard let i = resolveLayer(spec) else { log("unknown layer \"\(spec)\""); return }
                layerIndex = i
            }
            announceLayer()
            return
        }

        guard let k = KeyStroke.parse(action) else {
            log("cannot parse action \"\(action)\" on \(button.rawValue)"); return
        }
        KeySynth.tap(k)
    }

    private func resolveLayer(_ spec: String) -> Int? {
        if let i = Int(spec), i >= 0, i < config.layers.count { return i }
        return config.layers.firstIndex { $0.name == spec }
    }

    private func announceLayer() {
        let name = currentLayerName
        log("layer -> \(name)")
        guard config.s.soundOnLayer else { return }
        // Distinct pitch per layer so you can tell where you are without looking.
        let sounds = ["Tink", "Pop", "Morse", "Bottle", "Frog"]
        NSSound(named: sounds[effectiveLayer % sounds.count])?.play()
    }

    // MARK: - Teardown

    func releaseEverything() {
        for (_, st) in states {
            st.cancelTimers()
            st.heldKeyGuard?.invalidate(); st.heldKeyGuard = nil
            if let k = st.heldKey { KeySynth.up(k); st.heldKey = nil }
            st.momentaryLayer = nil
            st.tapCount = 0
        }
    }

    private func log(_ s: String) { Log.write(s) }
}
