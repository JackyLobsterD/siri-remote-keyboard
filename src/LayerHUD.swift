import AppKit

/// A brief overlay naming the layer just switched to, like the volume HUD.
/// Non-activating and click-through, so it never steals focus from what you're
/// typing into.
final class LayerHUD {
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    func show(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 30, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.sizeToFit()

        let pad = NSSize(width: 44, height: 22)
        let size = NSSize(width: max(label.frame.width + pad.width * 2, 160),
                          height: label.frame.height + pad.height * 2)

        let p = panel ?? makePanel()
        panel = p
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        label.frame.origin = NSPoint(x: (size.width - label.frame.width) / 2,
                                     y: (size.height - label.frame.height) / 2)
        blur.addSubview(label)
        p.contentView = blur

        // The screen you're looking at is the one with the pointer.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + f.height * 0.18,
                              width: size.width, height: size.height), display: true)
        }

        hide?.cancel()
        p.alphaValue = 1
        p.orderFrontRegardless()
        let w = DispatchWorkItem { [weak p] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                p?.animator().alphaValue = 0
            }, completionHandler: { p?.orderOut(nil) })
        }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return p
    }
}
