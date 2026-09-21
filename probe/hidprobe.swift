// hidprobe.swift — dump every HID device + live input events, so we can see
// exactly what the Siri Remote emits (especially the side Siri button).
//
//   swiftc -O hidprobe.swift -o hidprobe && ./hidprobe          # list devices
//   ./hidprobe watch                                            # watch ALL devices
//   ./hidprobe watch 0x004c 0x0315                              # watch one device
//
// Needs Input Monitoring permission for the terminal running it.

import Foundation
import IOKit.hid

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered: we tail this log live

let args = CommandLine.arguments
let watching = args.count > 1 && args[1] == "watch"
let wantVendor  = args.count > 3 ? Int(args[2].dropFirst(2), radix: 16) : nil
let wantProduct = args.count > 3 ? Int(args[3].dropFirst(2), radix: 16) : nil

func prop(_ d: IOHIDDevice, _ key: String) -> Int? {
    IOHIDDeviceGetProperty(d, key as CFString) as? Int
}
func propStr(_ d: IOHIDDevice, _ key: String) -> String {
    (IOHIDDeviceGetProperty(d, key as CFString) as? String) ?? "-"
}
func describe(_ d: IOHIDDevice) -> String {
    let v = prop(d, kIOHIDVendorIDKey) ?? 0
    let p = prop(d, kIOHIDProductIDKey) ?? 0
    let up = prop(d, kIOHIDPrimaryUsagePageKey) ?? 0
    let u  = prop(d, kIOHIDPrimaryUsageKey) ?? 0
    return String(format: "v=0x%04x p=0x%04x usagePage=0x%02x usage=0x%02x  %@ / %@",
                  v, p, up, u, propStr(d, kIOHIDManufacturerKey), propStr(d, kIOHIDProductKey))
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
if let wv = wantVendor, let wp = wantProduct {
    // Match ONLY this device, or the callback also fires for the built-in keyboard.
    IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: wv, kIOHIDProductIDKey: wp] as CFDictionary)
} else {
    IOHIDManagerSetDeviceMatching(manager, nil)   // match everything
}
IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
    FileHandle.standardError.write("no devices (grant Input Monitoring?)\n".data(using: .utf8)!)
    exit(1)
}
let devices = Array(set).sorted { describe($0) < describe($1) }

if !watching {
    print("=== \(devices.count) HID devices ===")
    for d in devices { print("  " + describe(d)) }
    print("\nRun `./hidprobe watch` (or `watch 0x004c 0x0315`) and press remote buttons.")
    exit(0)
}

let targets = devices.filter { d in
    guard let wv = wantVendor, let wp = wantProduct else { return true }
    return prop(d, kIOHIDVendorIDKey) == wv && prop(d, kIOHIDProductIDKey) == wp
}
print("=== watching \(targets.count) device(s) ===")
for d in targets { print("  " + describe(d)) }
print("Press buttons. Ctrl-C to stop.\n")

let start = Date()
let callback: IOHIDValueCallback = { _, _, sender, value in
    let el   = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(el)
    let use  = IOHIDElementGetUsage(el)
    let v    = IOHIDValueGetIntegerValue(value)
    // Skip the constant/padding noise
    if page == 0xFF00 && v == 0 { return }
    let dev = unsafeBitCast(sender, to: IOHIDDevice.self)
    let pid = prop(dev, kIOHIDProductIDKey) ?? 0
    let t = String(format: "%7.3f", Date().timeIntervalSince(start))
    print(String(format: "[%@] p=0x%04x  page=0x%02x usage=0x%02x  value=%d  (%@)",
                 t, pid, page, use, v, usageName(page: page, usage: use)))
}

func usageName(page: UInt32, usage: UInt32) -> String {
    switch (page, usage) {
    case (0x01, 0x30): return "X"
    case (0x01, 0x31): return "Y"
    case (0x07, _):    return "Keyboard key 0x\(String(usage, radix: 16))"
    case (0x0C, 0xB0): return "Play"
    case (0x0C, 0xCD): return "Play/Pause"
    case (0x0C, 0xE2): return "Mute"
    case (0x0C, 0xE9): return "Volume Up"
    case (0x0C, 0xEA): return "Volume Down"
    case (0x0C, 0x221): return "AC Search / Siri"
    case (0x0C, 0x223): return "AC Home / TV"
    case (0x0C, 0x224): return "AC Back / Menu"
    case (0x0C, 0x40):  return "Menu"
    case (0x0C, 0x30):  return "Power"
    case (0x0C, 0x42):  return "Menu Up"
    case (0x0C, 0x43):  return "Menu Down"
    case (0x0C, 0x44):  return "Menu Left"
    case (0x0C, 0x45):  return "Menu Right"
    case (0x0C, 0x41):  return "Menu Pick / Center"
    default: return "?"
    }
}

IOHIDManagerRegisterInputValueCallback(manager, callback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
CFRunLoopRun()
