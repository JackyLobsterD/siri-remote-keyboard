# siriremoted

Turn an Apple **Siri Remote (3rd gen, 2022, USB-C)** into a programmable macOS keyboard:
configurable per-button tap / double-tap / triple-tap / hold gestures, layers, and
hold-to-talk voice dictation.

Written because the obvious tools don't work: Karabiner-Elements
[cannot see the device at all](https://github.com/pqrs-org/Karabiner-Elements/issues/2824)
(closed as not planned), and BetterTouchTool has no support for it either.

## What actually works

Everything below was verified against real hardware, not inferred from docs.

### The twelve readable inputs

| Button | HID usage | | Button | HID usage |
|---|---|---|---|---|
| ring up | `0x0C/0x42` | | back `<` | `0x01/0x86` |
| ring down | `0x0C/0x43` | | TV | `0x0C/0x60` |
| ring left | `0x0C/0x44` | | play/pause | `0x0C/0xCD` |
| ring right | `0x0C/0x45` | | mute | `0x0C/0xE2` |
| ring center | `0x0C/0x80` | | volume up / down | `0x0C/0xE9` `0xEA` |
| | | | **Siri (side)** | **`0x0C/0x04`** |

The side Siri button reports clean press and release events, so its hold duration is
usable — that is what makes push-to-talk possible.

The touch surface is **not** readable. Its Digitizer interface (`0x0D/0x01`) stays
completely silent under IOHIDManager; reading it needs the private
MultitouchSupport framework.

### Getting macOS to let go of the buttons

This is the part that decides whether the whole idea is viable, and the obvious
approach fails:

- **`IOHIDDeviceOpen` with `kIOHIDOptionsTypeSeizeDevice` does not work.** It returns
  `kIOReturnSuccess` on all 7 interfaces, and the system goes right on handling the
  events anyway — volume keys still move the volume, play/pause still starts music.
- **`hidutil` driver-level remapping does work.** Mapping each usage to the keyboard
  page's "no event" (`0x0700000000`), scoped to the remote by vendor/product, stops
  macOS acting on the buttons.

The useful part: **IOHIDManager still delivers the original usage** after the remap.
So the system goes quiet while we keep full fidelity on all twelve buttons — no need
to encode each button as a distinct decoy keystroke.

`hidutil` settings do not survive a reboot, a wake, or a remote reconnect, so the
daemon reapplies them on every device-matching callback.

## Requirements

- macOS 13+, Xcode command-line tools (`swiftc`)
- Siri Remote **3rd gen** (`0x004C`/`0x0315`). Earlier generations report different
  usages and are untested.
- Accessibility and Input Monitoring permissions

## Install

Pair the remote first: hold **`<`** + **volume up** for five seconds, then connect
from System Settings → Bluetooth. It appears as a hex serial number, not as
"Siri Remote".

> Pairing the remote to a Mac **unpairs it from your Apple TV.**

```sh
./build.sh
open SiriRemoted.app
```

Grant Accessibility (and Input Monitoring if prompted) when asked, then launch again.
The `.app` wrapper is not cosmetic: TCC keys off a stable code-signing identity, so a
bare binary would re-prompt and would attach the permission to whichever terminal
launched it.

Logs go to `~/Library/Logs/siriremoted.log`.

To stop and restore stock remote behaviour: `pkill -f siriremoted`.

## Configuration

`~/.config/siriremote/config.jsonc`, hot-reloaded on save. Comments allowed.

```jsonc
{
  "settings": { "doubleTapWindowMs": 280, "holdThresholdMs": 350 },
  "layers": [{
    "name": "base",
    "bindings": {
      "ringUp":    { "tap": "up", "repeat": true },
      "center":    { "tap": "return" },
      "back":      { "tap": "escape" },
      "mute":      { "tap": "ctrl+tab" },
      "playPause": { "tap": "layer:next" },
      "siri":      { "whileHeld": "rightoption" },
      "tv":        { "whileHeld": "layerMomentary:1" }
    }
  }]
}
```

Buttons: `ringUp ringDown ringLeft ringRight center back tv playPause mute volUp
volDown siri`

Gestures: `tap` `double` `triple` `hold` `hold2` `whileHeld`, plus `"repeat": true`
for auto-repeat while held.

Actions: any keystroke (`"ctrl+tab"`, `"cmd+shift+p"`, `"pageup"`), `"layer:next"`,
`"layer:prev"`, `"layer:<n|name>"`, `"layerMomentary:<n|name>"`, or `"none"`.

A tap fires immediately unless the button also defines `double` or `triple`, in which
case it waits out `doubleTapWindowMs` — so navigation keys stay responsive.

### Push-to-talk

`"siri": { "whileHeld": "rightoption" }` holds right Option for exactly as long as the
side button is down. [Wispr Flow](https://wisprflow.ai) already binds right Option
(keycode 61) and Fn (63) to push-to-talk, so this needs no setup there.

To use a dedicated key instead, add one in Wispr's settings and change `whileHeld` to
match, e.g. `"f18"`.

Any `whileHeld` key is force-released on exit and by a `maxHeldKeySeconds` watchdog,
so a crash or a dropped Bluetooth packet can't leave a modifier stuck down.

### Note on the remote's microphone

Dictation uses **the Mac's microphone**, not the remote's. The remote's mic streams
over proprietary BLE GATT notifications that macOS does not expose as an audio input
device; capturing it requires HCI packet capture plus a CoreAudio HAL plugin. This
project deliberately doesn't go there — the side button is just a button.

## Probes

`probe/` holds the throwaway tools used to establish the above:

- `hidprobe.swift` — list HID devices; `watch` dumps live usage/value events
- `seizetest.swift` — demonstrates that seizing the device does not suppress it

```sh
cd probe
swiftc -O hidprobe.swift -o hidprobe
./hidprobe                       # list devices
./hidprobe watch 0x004c 0x0315   # watch the remote
```

## Related projects

Other people have driven this remote from macOS; they differ in scope:

- [SiriRemoteForge](https://github.com/HOLODATA-COM/SiriRemoteForge) — the most complete
  one. Adds trackpad cursor control (via the private MultitouchSupport framework) and an
  experimental virtual microphone that decodes the remote's own mic over BLE. Much larger
  surface area; this project deliberately stays smaller and keeps to public APIs.
- [Remotastic](https://github.com/lauschue/Remotastic), [VibeController](https://github.com/michaello/VibeController) —
  menu-bar apps aimed at pointer/media control rather than gesture layers.
- [codex-siri-remote](https://github.com/luobosibing2/codex-siri-remote) — same hardware,
  wired to one specific application.
- [SiriRemoteVoiceDecoder](https://github.com/Jack-R1/SiriRemoteVoiceDecoder) — the Opus
  decoding work behind reading the remote's microphone.

## License

MIT
