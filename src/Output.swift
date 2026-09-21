import Foundation
import CoreGraphics

/// Where synthesised keys go: this Mac, or the relay target picked on the remote.
enum Output {
    static var host: RelayHost?

    /// nil means this Mac.
    static var target: String? { host?.current }

    static func tap(_ k: KeyStroke) {
        if let t = target { send(t, "tap", k) } else { KeySynth.tap(k) }
    }

    /// Returns where the key went down, so its release follows it there even if
    /// the target changes while it is still held.
    static func down(_ k: KeyStroke) -> String? {
        let t = target
        if let t { send(t, "down", k) } else { KeySynth.down(k) }
        return t
    }

    static func up(_ k: KeyStroke, to t: String?) {
        if let t { send(t, "up", k) } else { KeySynth.up(k) }
    }

    private static func send(_ t: String, _ kind: String, _ k: KeyStroke) {
        let m = RelayMessage(t: kind, code: UInt16(k.code), flags: k.flags.rawValue)
        if host?.send(to: t, m) != true { Log.write("relay: \(kind) for \(t) dropped — not connected") }
    }
}
