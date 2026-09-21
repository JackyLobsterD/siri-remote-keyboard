import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Click, then press the combination you want. Captures at the AppKit level, so
/// it records the Mac keyboard — unrelated to the remote's own HID stream.
struct KeyRecorder: NSViewRepresentable {
    @Binding var value: String            // "ctrl+tab"
    var onChange: (String) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.onCapture = { s in value = s; onChange(s) }
        v.display = value
        return v
    }

    func updateNSView(_ v: RecorderView, context: Context) {
        v.display = value
        v.needsDisplay = true
    }
}

final class RecorderView: NSView {
    var onCapture: ((String) -> Void)?
    var display: String = ""
    private var recording = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    override func mouseDown(with event: NSEvent) {
        recording.toggle()
        if recording { window?.makeFirstResponder(self) }
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        // Escape alone cancels rather than binding Escape — use the Clear button
        // in the row to unbind, or press Escape twice.
        if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            recording = false; needsDisplay = true
            window?.makeFirstResponder(nil)
            return
        }
        guard let s = Self.describe(event) else { NSSound.beep(); return }
        display = s
        recording = false
        onCapture?(s)
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    /// NSEvent -> the "cmd+shift+p" form the config uses.
    static func describe(_ e: NSEvent) -> String? {
        guard let name = codeToName[e.keyCode] else { return nil }
        var mods: [String] = []
        let f = e.modifierFlags
        if f.contains(.control) { mods.append("ctrl") }
        if f.contains(.option)  { mods.append("opt") }
        if f.contains(.shift)   { mods.append("shift") }
        if f.contains(.command) { mods.append("cmd") }
        return (mods + [name]).joined(separator: "+")
    }

    /// Reverse of the keyCodes table, preferring the canonical spelling.
    static let codeToName: [UInt16: String] = {
        var out: [UInt16: String] = [:]
        let preferred = Set(["return","tab","space","delete","escape","up","down",
                             "left","right","pageup","pagedown","home","end"])
        for (name, code) in keyCodes {
            let k = UInt16(code)
            if out[k] == nil || preferred.contains(name) { out[k] = name }
        }
        return out
    }()

    override func draw(_ dirtyRect: NSRect) {
        let bg = recording ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                           : NSColor.unemphasizedSelectedContentBackgroundColor
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        bg.setFill(); path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()

        let text = recording ? "按下按键…" : (display.isEmpty ? "点击设置" : KeyStroke.prettify(display))
        let color: NSColor = recording ? .controlAccentColor
                           : (display.isEmpty ? .tertiaryLabelColor : .labelColor)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: display.isEmpty ? .regular : .medium),
            .foregroundColor: color,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}
