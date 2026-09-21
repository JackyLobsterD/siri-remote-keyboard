import Foundation
import IOKit.hid

let VENDOR  = 0x004C
let PRODUCT = 0x0315   // Siri Remote, 3rd gen (2022, USB-C)

/// Owns the HID connection, the driver-level suppression, and the gesture engine.
final class RemoteService {
    let engine: Engine
    private var manager: IOHIDManager?
    private var watcher: ConfigWatcher?
    private(set) var paused = false
    private(set) var connected = false

    var onStateChange: (() -> Void)?

    init(config: Config) {
        engine = Engine(config: config)
        engine.onLayerChange = { [weak self] in self?.onStateChange?() }
    }

    // MARK: Driver-level suppression
    //
    // Seizing the device (kIOHIDOptionsTypeSeizeDevice) succeeds on all seven
    // interfaces but suppresses nothing. Remapping each usage to the keyboard
    // page's "no event" does work, and IOHIDManager still reports the original
    // usage to us, so every button stays distinguishable.

    private static let noEvent: UInt64 = 0x07_00000000

    static func neutralize() {
        let entries = usageToButton.keys.sorted().map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0),\"HIDKeyboardModifierMappingDst\":\(noEvent)}"
        }
        hidutil("{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}")
    }

    static func restore() { hidutil("{\"UserKeyMapping\":[]}") }

    @discardableResult
    private static func hidutil(_ payload: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = ["property", "--matching",
                       "{\"VendorID\":\(VENDOR),\"ProductID\":\(PRODUCT)}",
                       "--set", payload]
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { Log.write("hidutil failed: \(error)"); return false }
    }

    // MARK: Lifecycle

    func start() -> Bool {
        RemoteService.neutralize()

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr,
            [kIOHIDVendorIDKey: VENDOR, kIOHIDProductIDKey: PRODUCT] as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterInputValueCallback(mgr, { ctx, _, _, value in
            guard let ctx else { return }
            let me = Unmanaged<RemoteService>.fromOpaque(ctx).takeUnretainedValue()
            guard !me.paused else { return }
            let el = IOHIDValueGetElement(value)
            let key = (UInt64(IOHIDElementGetUsagePage(el)) << 32) | UInt64(IOHIDElementGetUsage(el))
            guard let button = usageToButton[key] else { return }
            me.engine.handle(button, pressed: IOHIDValueGetIntegerValue(value) != 0)
        }, ctx)

        // hidutil mappings do not survive a reconnect or a wake, so reapply on
        // every match.
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, _ in
            RemoteService.neutralize()
            guard let ctx else { return }
            let me = Unmanaged<RemoteService>.fromOpaque(ctx).takeUnretainedValue()
            me.connected = true
            me.onStateChange?()
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, _ in
            guard let ctx else { return }
            let me = Unmanaged<RemoteService>.fromOpaque(ctx).takeUnretainedValue()
            me.connected = false
            me.engine.releaseEverything()
            me.onStateChange?()
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            Log.write("could not open HID manager — grant Input Monitoring")
            return false
        }
        manager = mgr

        if let devs = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !devs.isEmpty {
            connected = true
            Log.write("remote connected (\(devs.count) interfaces)")
        } else {
            Log.write("remote not connected yet — waiting")
        }

        watcher = ConfigWatcher(path: Config.path) { [weak self] in
            do { self?.engine.reload(try Config.load()) }
            catch { Log.write("config reload failed, keeping previous: \(error)") }
            self?.onStateChange?()
        }
        watcher?.start()
        return true
    }

    func setPaused(_ p: Bool) {
        paused = p
        if p {
            engine.releaseEverything()
            RemoteService.restore()      // hand the buttons back to macOS
        } else {
            RemoteService.neutralize()
        }
        Log.write(p ? "paused — remote back to stock" : "resumed")
        onStateChange?()
    }

    /// Always leave the machine as we found it: nothing held, nothing remapped.
    func shutdown() {
        engine.releaseEverything()
        RemoteService.restore()
        Log.write("stopped; remote restored to stock behaviour")
    }
}
