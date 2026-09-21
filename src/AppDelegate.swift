import AppKit
import SwiftUI
import ApplicationServices
import IOKit.hid

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var service: RemoteService?
    private var store: ConfigStore?
    private var settingsWindow: NSWindow?
    private var trustTimer: Timer?
    private var permissionsWindow: NSWindow?
    private let permissions = PermissionModel()
    private let relayStatus = RelayStatus()
    private var relayHost: RelayHost?
    private var relayReceiver: RelayReceiver?

    func applicationDidFinishLaunching(_ note: Notification) {
        buildStatusItem()
        // The settings window changes role/passcode; a relaunch applies them.
        NotificationCenter.default.addObserver(forName: .siriRemotedRelaunch, object: nil,
                                               queue: .main) { [weak self] _ in self?.relaunch() }
        if permissions.allGranted { startEverything() } else { startPermissionFlow() }
    }

    func applicationWillTerminate(_ note: Notification) {
        relayHost?.stop()
        relayReceiver?.stop()
        service?.shutdown()
    }

    // MARK: Permissions
    //
    // Accessibility (synthesise keystrokes) and Input Monitoring (read the
    // remote) are granted separately. A modal alert was the wrong shape here:
    // dismissing it to open one pane left no way back to the other. A plain
    // window with live status per permission stays open until both are done.

    private func startPermissionFlow() {
        permissions.request()

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 340),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "SiriRemoted 权限"
        w.contentView = NSHostingView(rootView: PermissionsView(model: permissions) { [weak self] in
            self?.relaunch()
        })
        w.center()
        w.isReleasedWhenClosed = false
        permissionsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)

        // .common mode matters: a timer in .default stops firing whenever any
        // modal loop (including the system's own prompts) is up, which is what
        // made granting appear to do nothing.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.permissions.refresh()
            self.refreshMenu()
            guard self.permissions.allGranted else { return }
            timer.invalidate()
            self.permissionsWindow?.close()
            self.startEverything()
        }
        RunLoop.main.add(t, forMode: .common)
        trustTimer = t
        refreshMenu()
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Boot

    private func startEverything() {
        let config: Config
        do { config = try Config.load() }
        catch {
            Log.write("config error: \(error)")
            let a = NSAlert()
            a.messageText = "配置文件读不了"
            a.informativeText = "\(Config.path)\n\n\(error)"
            a.runModal()
            return
        }
        let store = ConfigStore(config: config)
        self.store = store

        if RelaySettings.role == .receiver {
            // A receiver has no remote of its own; it only types what a host sends.
            let rx = RelayReceiver(status: relayStatus)
            rx.onChange = { [weak self] in self?.refreshMenu() }
            relayReceiver = rx
            rx.start()
            refreshMenu()
            return
        }

        let svc = RemoteService(config: config)
        svc.onStateChange = { [weak self] in
            DispatchQueue.main.async { self?.syncStoreFromDisk(); self?.refreshMenu() }
        }
        self.service = svc
        _ = svc.start()

        if RelaySettings.role == .host {
            let announcer = Announcer()
            announcer.enabled = { [weak svc] in svc?.engine.soundsEnabled ?? true }
            let host = RelayHost(status: relayStatus, announcer: announcer)
            host.onChange = { [weak self] in self?.refreshMenu() }
            svc.engine.onTargetAction = { [weak host] spec in host?.select(spec) }
            Output.host = host
            relayHost = host
            host.start()
        }
        refreshMenu()
    }

    /// Pick up hand edits to the config file, but don't stomp on the settings
    /// window right after it saved.
    private func syncStoreFromDisk() {
        guard let store, Date().timeIntervalSince(store.lastSave) > 1.0 else { return }
        if let fresh = try? Config.load() { store.config = fresh }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            let names = ["appletvremote.gen4", "av.remote.fill", "dot.radiowaves.left.and.right"]
            for n in names {
                if let img = NSImage(systemSymbolName: n, accessibilityDescription: "Siri Remote") {
                    b.image = img
                    break
                }
            }
            if b.image == nil { b.title = "⌾" }
        }
        refreshMenu()
    }

    private func refreshMenu() {
        let menu = NSMenu()

        let statusLine: String
        if !permissions.accessibility   { statusLine = "⚠︎ 缺「辅助功能」权限" }
        else if !permissions.inputMonitoring { statusLine = "⚠︎ 缺「输入监控」权限" }
        else if permissions.needsRelaunch    { statusLine = "⚠︎ 需重启 App 生效" }
        else if RelaySettings.role == .receiver {
            statusLine = relayStatus.receiverConnections > 0
                ? "● 接收端「\(RelaySettings.name)」· 已被宿主机连接"
                : "○ 接收端「\(RelaySettings.name)」· 等待宿主机"
        }
        else if service == nil          { statusLine = "未启动" }
        else if service?.paused == true { statusLine = "已暂停（遥控器恢复原厂行为）" }
        else if service?.connected == true { statusLine = "● 遥控器已连接" }
        else                            { statusLine = "○ 等待遥控器连接" }
        menu.addItem(disabled(statusLine))

        if let e = service?.engine, service?.paused == false {
            menu.addItem(disabled("Layer：\(e.currentLayerName)"))
        }
        if let host = relayHost {
            menu.addItem(.separator())
            menu.addItem(disabled("控制的电脑"))
            let names: [String?] = [nil] + host.readyNames.map { Optional($0) }
            for n in names {
                let item = NSMenuItem(title: n ?? "本机（\(RelaySettings.name)）",
                                      action: #selector(pickTarget(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = n ?? "local"
                item.state = (host.current == n) ? .on : .off
                menu.addItem(item)
            }
            let others = relayStatus.peers.filter { !$0.ready }
            for p in others { menu.addItem(disabled("   \(p.name) — \(p.state)")) }
            if !relayStatus.note.isEmpty { menu.addItem(disabled("   \(relayStatus.note)")) }
        }
        menu.addItem(.separator())

        if !permissions.allGranted {
            let perm = NSMenuItem(title: "权限设置…", action: #selector(openPermissions), keyEquivalent: "")
            perm.target = self
            menu.addItem(perm)
        }

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.isEnabled = store != nil
        menu.addItem(settings)

        let pause = NSMenuItem(title: service?.paused == true ? "继续" : "暂停",
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.isEnabled = service != nil
        menu.addItem(pause)

        menu.addItem(.separator())
        let log = NSMenuItem(title: "打开日志", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 SiriRemoted", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func disabled(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    // MARK: Actions

    @objc private func pickTarget(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? String else { return }
        relayHost?.select(spec)
        refreshMenu()
    }

    @objc private func openPermissions() {
        permissions.refresh()
        if permissionsWindow == nil { startPermissionFlow(); return }
        NSApp.activate(ignoringOtherApps: true)
        permissionsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        guard let store else { return }
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = "SiriRemoted 设置"
            w.contentView = NSHostingView(rootView: SettingsView(store: store, relay: relayStatus))
            w.center()
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePause() {
        guard let service else { return }
        service.setPaused(!service.paused)
        refreshMenu()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let siriRemotedRelaunch = Notification.Name("SiriRemotedRelaunch")
}
