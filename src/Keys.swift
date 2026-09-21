import Foundation
import CoreGraphics

/// The twelve inputs we can actually read from the 3rd-gen Siri Remote.
/// (The touch surface is deliberately absent: its Digitizer interface stays
/// silent under IOHIDManager, it needs the private MultitouchSupport framework.)
enum Button: String, CaseIterable {
    case ringUp, ringDown, ringLeft, ringRight, center
    case back, tv, playPause, mute, volUp, volDown, siri
}

/// (usagePage << 32) | usage  ->  button. Values confirmed by probing the real device.
let usageToButton: [UInt64: Button] = [
    0x0C_00000042: .ringUp,
    0x0C_00000043: .ringDown,
    0x0C_00000044: .ringLeft,
    0x0C_00000045: .ringRight,
    0x0C_00000080: .center,
    0x01_00000086: .back,
    0x0C_00000060: .tv,
    0x0C_000000CD: .playPause,
    0x0C_000000E2: .mute,
    0x0C_000000E9: .volUp,
    0x0C_000000EA: .volDown,
    0x0C_00000004: .siri,
]

// MARK: - Key names

let keyCodes: [String: CGKeyCode] = [
    "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,
    "w":13,"e":14,"r":15,"y":16,"t":17,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,
    "k":40,"n":45,"m":46,
    "1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25,"0":29,
    "return":36,"enter":36,"tab":48,"space":49,"delete":51,"backspace":51,
    "escape":53,"esc":53,"forwarddelete":117,
    "left":123,"right":124,"down":125,"up":126,
    "leftarrow":123,"rightarrow":124,"downarrow":125,"uparrow":126,
    "pageup":116,"pagedown":121,"home":115,"end":119,
    "f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,
    "f9":101,"f10":109,"f11":103,"f12":111,"f13":105,"f14":107,"f15":113,
    "f16":106,"f17":64,"f18":79,"f19":80,"f20":90,
    "minus":27,"equal":24,"leftbracket":33,"rightbracket":30,"backslash":42,
    "semicolon":41,"quote":39,"comma":43,"period":47,"slash":44,"grave":50,
    // Modifiers, addressable as real keys so they can be *held* (Wispr PTT).
    "command":55,"shift":56,"capslock":57,"option":58,"control":59,
    "rightshift":60,"rightoption":61,"rightcontrol":62,"fn":63,
]

let modifierFlags: [String: CGEventFlags] = [
    "cmd": .maskCommand, "command": .maskCommand,
    "ctrl": .maskControl, "control": .maskControl,
    "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate,
    "shift": .maskShift,
    "fn": .maskSecondaryFn,
]

/// Flag a modifier key implies when held on its own, so Wispr sees a real
/// right-Option press rather than a bare keycode with no flags.
let selfFlag: [CGKeyCode: CGEventFlags] = [
    55: .maskCommand, 56: .maskShift, 58: .maskAlternate, 59: .maskControl,
    60: .maskShift, 61: .maskAlternate, 62: .maskControl, 63: .maskSecondaryFn,
]

struct KeyStroke: Equatable {
    var code: CGKeyCode
    var flags: CGEventFlags

    /// "ctrl+tab", "cmd+shift+p", "pageup", "rightoption"
    static func parse(_ s: String) -> KeyStroke? {
        let parts = s.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last, let code = keyCodes[last] else { return nil }
        var flags: CGEventFlags = []
        for m in parts.dropLast() {
            guard let f = modifierFlags[m] else { return nil }
            flags.insert(f)
        }
        return KeyStroke(code: code, flags: flags)
    }
}

// MARK: - Synthesis

enum KeySynth {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static func down(_ k: KeyStroke) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: k.code, keyDown: true) else { return }
        e.flags = k.flags.union(selfFlag[k.code] ?? [])
        e.post(tap: .cghidEventTap)
    }

    static func up(_ k: KeyStroke) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: k.code, keyDown: false) else { return }
        // Releasing a modifier must clear its own flag, or the OS keeps thinking it is down.
        e.flags = k.flags.subtracting(selfFlag[k.code] ?? [])
        e.post(tap: .cghidEventTap)
    }

    static func tap(_ k: KeyStroke) { down(k); up(k) }
}
