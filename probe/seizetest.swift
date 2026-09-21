// seizetest.swift — can we SEIZE the remote's HID interfaces, so macOS stops
// acting on its buttons (volume actually changing, media actually playing)?
// That's the difference between "logging the remote" and "using it as a keyboard".
//
//   swiftc -O seizetest.swift -o seizetest && ./seizetest

import Foundation
import IOKit.hid

setvbuf(stdout, nil, _IONBF, 0)

let VENDOR = 0x004c, PRODUCT = 0x0315

func prop(_ d: IOHIDDevice, _ k: String) -> Int? { IOHIDDeviceGetProperty(d, k as CFString) as? Int }

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
// Match ONLY the remote this time (the earlier probe leaked the built-in keyboard).
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: VENDOR, kIOHIDProductIDKey: PRODUCT] as CFDictionary)
IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))

guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty else {
    print("remote not found — is it connected?"); exit(1)
}

print("=== attempting SEIZE on each interface ===")
var seized: [IOHIDDevice] = []
for d in Array(set) {
    let up = prop(d, kIOHIDPrimaryUsagePageKey) ?? 0
    let u  = prop(d, kIOHIDPrimaryUsageKey) ?? 0
    let r  = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    let tag = String(format: "usagePage=0x%02x usage=0x%02x", up, u)
    if r == kIOReturnSuccess { seized.append(d); print("  SEIZED   \(tag)") }
    else { print(String(format: "  FAILED   %@  (IOReturn 0x%08x)", tag, r)) }
}
print("\nseized \(seized.count)/\(set.count) interfaces")
guard !seized.isEmpty else { exit(1) }

print("""

Now press VOLUME UP / DOWN and PLAY-PAUSE a few times, then the SIRI side button.
  - events print below  => we still receive input
  - system volume does NOT move, nothing starts playing => seize works, we own the device
Ctrl-C to release.

""")

let cb: IOHIDValueCallback = { _, _, _, value in
    let el = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(el), use = IOHIDElementGetUsage(el)
    let v = IOHIDValueGetIntegerValue(value)
    if page == 0xFF00 { return }
    print(String(format: "  page=0x%02x usage=0x%02x value=%d", page, use, v))
}
for d in seized { IOHIDDeviceRegisterInputValueCallback(d, cb, nil)
                  IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) }

signal(SIGINT) { _ in print("\nreleasing…"); exit(0) }
CFRunLoopRun()
