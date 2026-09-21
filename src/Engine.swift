import Foundation
import AppKit

private final class ButtonState {
    var tapCount = 0
    var resolveTimer: Timer?
    var holdTimers: [Timer] = []
    var repeatTimer: Timer?
    var holdFired = false
    var heldKey: KeyStroke?
    /// Which Mac the held key went down on (nil = this one), so it is released there.
    var heldTarget: String?
    var heldKeyGuard: Timer?
    var momentaryLayer: Int?
    var activeBinding: ButtonBinding?

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

    /// Fired when the active layer changes, so the menu bar can follow along.
    var onLayerChange: (() -> Void)?

    /// "target:next" and friends — which Mac the remote drives. Handled by the
    /// relay host; a no-op when relaying is off.
    var onTargetAction: ((String) -> Void)?

    var soundsEnabled: Bool { config.s.soundOnLayer }

    /// A one-shot ("leader") layer: armed by one button, consumed by the next
    /// press, and dropped if nothing follows in time. Unlike a momentary layer
    /// it needs no key held down, so it works one-handed with a thumb.
    private var oneShotLayer: Int?
    private var oneShotTimer: Timer?

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
        return oneShotLayer ?? layerIndex
    }

    var isLeaderArmed: Bool { oneShotLayer != nil }

    private func armOneShot(_ i: Int) {
        oneShotTimer?.invalidate()
        oneShotLayer = i
        oneShotTimer = Timer.scheduledTimer(
            withTimeInterval: config.s.oneShotTimeout, repeats: false) { [weak self] _ in
            guard let self, self.oneShotLayer != nil else { return }
            self.oneShotLayer = nil
            self.log("leader timed out")
            self.announce(.leaderExpired)
        }
        log("leader armed -> \(currentLayerName)")
        announce(.leaderArmed)
    }

    /// Any press other than the one that armed it spends the leader.
    private func consumeOneShot() {
        guard oneShotLayer != nil else { return }
        oneShotTimer?.invalidate(); oneShotTimer = nil
        oneShotLayer = nil
    }

    private func binding(for b: Button) -> ButtonBinding? {
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

        let bind: ButtonBinding
        if pressed {
            guard let resolved = binding(for: button) else {
                // An unbound button still spends a pending leader, otherwise it
                // would linger and fire on some later, unrelated press.
                consumeOneShot()
                onLayerChange?()
                return
            }
            bind = resolved
            st.activeBinding = resolved
            let wasArmed = isLeaderArmed
            consumeOneShot()
            if wasArmed { onLayerChange?() }
        } else {
            guard let stored = st.activeBinding else { return }
            bind = stored
        }

        if let held = bind.whileHeld {
            if pressed {
                playKeySound(bind.sound)
                beginWhileHeld(button, st, held)
            } else {
                endWhileHeld(button, st)
            }
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

    private func resolveTaps(_ button: Button, _ st: ButtonState, _ bind: ButtonBinding) {
        let n = st.tapCount
        st.tapCount = 0
        st.resolveTimer?.invalidate(); st.resolveTimer = nil
        guard n > 0, let action = bind.action(forTaps: n) else { return }
        perform(action, from: button, state: st, sound: bind.sound)
    }

    private func scheduleHolds(_ button: Button, _ st: ButtonState, _ bind: ButtonBinding) {
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
                self?.perform(action, from: button, state: st, sound: bind.sound)
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
                if let k = KeyStroke.parse(action) { Output.tap(k) }
            }
        }
    }

    // MARK: - whileHeld (push-to-talk)

    private func beginWhileHeld(_ button: Button, _ st: ButtonState, _ action: String) {
        if action.hasPrefix("layerMomentary:") {
            let spec = String(action.dropFirst("layerMomentary:".count))
            if let i = resolveLayer(spec) { st.momentaryLayer = i; announce(.layerChanged) }
            return
        }
        guard let k = KeyStroke.parse(action) else {
            log("whileHeld: cannot parse \"\(action)\""); return
        }
        if st.heldKey != nil { endWhileHeld(button, st) }
        st.heldKey = k
        st.heldTarget = Output.down(k)
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
        if let k = st.heldKey { Output.up(k, to: st.heldTarget); st.heldKey = nil; st.heldTarget = nil }
        if st.momentaryLayer != nil { st.momentaryLayer = nil; announce(.layerChanged) }
    }

    // MARK: - Actions

    private func playKeySound(_ name: String?) {
        guard let name, config.s.soundOnLayer else { return }
        Sounds.play(name)
    }

    private func perform(_ action: String, from button: Button, state st: ButtonState,
                         sound: String? = nil) {
        if action == "none" { return }
        playKeySound(sound)

        if action.hasPrefix("target:") {
            let spec = String(action.dropFirst("target:".count))
            if let handler = onTargetAction { handler(spec) }
            else { log("target:\(spec) ignored — multi-Mac relay is off") }
            return
        }

        if action.hasPrefix("layerOneShot:") {
            let spec = String(action.dropFirst("layerOneShot:".count))
            guard let i = resolveLayer(spec) else { log("unknown layer \"\(spec)\""); return }
            armOneShot(i)
            return
        }

        if action.hasPrefix("layer:") {
            let spec = String(action.dropFirst("layer:".count))
            switch spec {
            case "next": layerIndex = step(from: layerIndex, by: 1)
            case "prev": layerIndex = step(from: layerIndex, by: -1)
            default:
                guard let i = resolveLayer(spec) else { log("unknown layer \"\(spec)\""); return }
                layerIndex = i
            }
            announce(.layerChanged)
            return
        }

        guard let k = KeyStroke.parse(action) else {
            log("cannot parse action \"\(action)\" on \(button.rawValue)"); return
        }
        Output.tap(k)
    }

    /// Walks to the next layer that cycling is allowed to land on.
    private func step(from: Int, by delta: Int) -> Int {
        let n = config.layers.count
        guard n > 0 else { return 0 }
        var i = from
        for _ in 0..<n {
            i = ((i + delta) % n + n) % n
            if config.layers[i].skipInCycle != true { return i }
        }
        return from
    }

    private func resolveLayer(_ spec: String) -> Int? {
        if let i = Int(spec), i >= 0, i < config.layers.count { return i }
        return config.layers.firstIndex { $0.name == spec }
    }

    /// What just happened, so each event gets its own sound. Keying sounds off
    /// the layer number made "armed" and "expired" indistinguishable.
    private enum Cue { case leaderArmed, leaderExpired, layerChanged }

    private func announce(_ cue: Cue) {
        log("layer -> \(currentLayerName)")
        onLayerChange?()
        guard config.s.soundOnLayer else { return }
        switch cue {
        case .leaderArmed:   Sounds.play(config.s.armedSound)
        case .leaderExpired: Sounds.play(config.s.expiredSound)
        case .layerChanged:  Sounds.play(config.s.switchSound)
        }
    }

    // MARK: - Teardown

    func releaseEverything() {
        oneShotTimer?.invalidate(); oneShotTimer = nil
        oneShotLayer = nil
        for (_, st) in states {
            st.activeBinding = nil
            st.cancelTimers()
            st.heldKeyGuard?.invalidate(); st.heldKeyGuard = nil
            if let k = st.heldKey { Output.up(k, to: st.heldTarget); st.heldKey = nil; st.heldTarget = nil }
            st.momentaryLayer = nil
            st.tapCount = 0
        }
    }

    private func log(_ s: String) { Log.write(s) }
}
