import Foundation
import IOKit.hid
import AppKit
import ApplicationServices

setvbuf(stdout, nil, _IONBF, 0)

let VENDOR = 0x004C
let PRODUCT = 0x0315   // Siri Remote, 3rd gen (2022, USB-C)

func log(_ s: String) { Log.write(s) }

// MARK: - Stop macOS from acting on the remote itself
//
// Seizing the device (kIOHIDOptionsTypeSeizeDevice) reports success but does
// NOT stop the system consuming these events — volume still moves. Remapping
// every usage to the keyboard page's "no event" at the driver level does stop
// it, and IOHIDManager still delivers the ORIGINAL usage to us, so we keep full
// fidelity while the system goes quiet.

let NO_EVENT: UInt64 = 0x07_00000000

func neutralizeButtons() {
    let entries = usageToButton.keys.sorted().map {
        "{\"HIDKeyboardModifierMappingSrc\":\($0),\"HIDKeyboardModifierMappingDst\":\(NO_EVENT)}"
    }
    let payload = "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
    runHidutil(payload)
}

func restoreButtons() {
    runHidutil("{\"UserKeyMapping\":[]}")
}

@discardableResult
func runHidutil(_ payload: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    p.arguments = ["property", "--matching",
                   "{\"VendorID\":\(VENDOR),\"ProductID\":\(PRODUCT)}",
                   "--set", payload]
    p.standardOutput = FileHandle.nullDevice
    p.standardError  = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
    catch { log("hidutil failed: \(error)"); return false }
}

// MARK: - Permissions

func ensureAccessibility() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(opts) {
        log("""
            Accessibility permission is required to synthesise keystrokes.
            Grant it in System Settings > Privacy & Security > Accessibility,
            then run this again.
            """)
        exit(1)
    }
}

// MARK: - Boot

ensureAccessibility()

var config: Config
do { config = try Config.load() }
catch { log("config error: \(error)"); exit(1) }

let engine = Engine(config: config)
log("loaded \(config.layers.count) layer(s); starting on \"\(engine.currentLayerName)\"")

neutralizeButtons()

// MARK: - Clean teardown
//
// Leaving a synthetic modifier down, or the remote neutralized, would both
// outlive this process. Always undo them.

func shutdown(_ code: Int32) -> Never {
    engine.releaseEverything()
    restoreButtons()
    log("stopped; remote restored to stock behaviour")
    exit(code)
}

for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { shutdown(0) }
    src.resume()
    signalSources.append(src)
}

// MARK: - HID

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager,
    [kIOHIDVendorIDKey: VENDOR, kIOHIDProductIDKey: PRODUCT] as CFDictionary)

let inputCallback: IOHIDValueCallback = { _, _, _, value in
    let el = IOHIDValueGetElement(value)
    let key = (UInt64(IOHIDElementGetUsagePage(el)) << 32) | UInt64(IOHIDElementGetUsage(el))
    guard let button = usageToButton[key] else { return }
    let v = IOHIDValueGetIntegerValue(value)
    engine.handle(button, pressed: v != 0)
}

// The hidutil mapping does not survive a reconnect or a wake, so reapply it
// every time an interface shows up again.
let matchCallback: IOHIDDeviceCallback = { _, _, _, _ in
    neutralizeButtons()
}

IOHIDManagerRegisterInputValueCallback(manager, inputCallback, nil)
IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
    log("could not open HID manager — grant Input Monitoring in System Settings")
    shutdown(1)
}

if let devs = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devs.isEmpty {
    log("remote connected (\(devs.count) interfaces)")
} else {
    log("remote not connected yet — waiting")
}

// MARK: - Hot reload

let watcher = ConfigWatcher(path: Config.path) {
    do { engine.reload(try Config.load()) }
    catch { log("config reload failed, keeping previous: \(error)") }
}
watcher.start()

log("ready. Ctrl-C to stop.")
CFRunLoopRun()
shutdown(0)
