import Foundation

/// Sounds, speech and the layer HUD/badge go to the Mac you're driving, not
/// the one the remote happens to be paired with — feedback on a screen you
/// aren't looking at, or from a speaker across the desk, is no feedback.
enum Feedback {
    static var announcer: Announcer?
    static var hud: LayerHUD?

    private static func remote(_ m: RelayMessage) -> Bool {
        guard let t = Output.target else { return false }
        if Output.host?.send(to: t, m) != true { Log.write("relay: \(m.t) for \(t) dropped") }
        return true
    }

    static func sound(_ id: String) {
        if !remote(RelayMessage(t: "sound", name: id)) { Sounds.play(id) }
    }

    static func speak(_ text: String) {
        guard announcer?.enabled() ?? true else { return }
        if !remote(RelayMessage(t: "announce", name: text)) { announcer?.say(text) }
    }

    static func showHUD(_ text: String) {
        if !remote(RelayMessage(t: "hud", name: text)) { hud?.show(text) }
    }
}
