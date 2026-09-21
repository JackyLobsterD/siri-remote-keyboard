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
./build.sh install      # builds, signs, copies to /Applications
open -a SiriRemoted
```

It is a menu-bar app (no Dock icon). A permissions window lists what it still
needs — Accessibility and Input Monitoring — with a button for each, and carries on
by itself once both are granted; no relaunch.

The `.app` wrapper is not cosmetic: TCC keys off the code-signing identity. An
ad-hoc signature is identified by its cdhash, which changes on every build, so macOS
silently drops the grants after each rebuild while still showing them as enabled.
`build.sh` signs with a local identity named `SiriRemoted Self-Signed` when one
exists in your keychain, which keeps grants across rebuilds; otherwise it falls back
to ad-hoc and you re-grant after rebuilding.

Logs go to `~/Library/Logs/siriremoted.log`. Quitting from the menu (or
`pkill -f siriremoted`) releases any held key and restores the remote to stock.

## Settings

The menu bar icon → **设置…** opens a window with three tabs:

- **按键** — the twelve buttons; for each, pick what tap / double / triple / hold /
  longer hold / while-held do, by recording a keystroke or choosing a layer or
  target action. Each button can also play a sound when it fires.
- **时间与通用** — tap and hold timing, leader timeout, and which sound plays for
  leader armed / leader expired / layer switch (any system sound, or files you drop
  into `~/Library/Sounds`).
- **多电脑** — multi-Mac relay, below.

Saving from the window rewrites the config as plain JSON, so hand-written comments
are lost; hand edits to the file still hot-reload.

## Leader key

Holding one button while pressing another is impossible one-thumbed — both are on
the top face. A **leader** (one-shot layer) avoids that: tap it, and the *next*
press resolves in the leader layer, then it disarms. If nothing follows within
`oneShotTimeoutMs` it expires. Each leader covers exactly one action, and every tap
re-arms it with a fresh timer.

```jsonc
"tv": { "tap": "layerOneShot:leader" }
```

## Multiple Macs

One remote can drive several Macs on the same network. The Mac the remote is paired
with is the **host**; the others run SiriRemoted as **receivers**. The host runs the
gesture engine and forwards only the resulting key presses, so the keymap lives in one
place. Switching is a key action — `"target:next"`, `"target:prev"`, `"target:local"`
or `"target:<name>"` — and the host speaks the name of the Mac it switched to.

- Receivers advertise themselves over Bonjour; the host finds them with no
  addresses to type in. No server, no Tailscale on a shared LAN.
- **Every connection is TLS with a pre-shared key derived from a passcode.** A
  receiver types whatever it is sent, so without this anyone on the same Wi-Fi could
  drive the Mac. A wrong passcode stalls the handshake; the host gives up after 5s
  and reports it as a likely passcode mismatch.
- A key held on a receiver (push-to-talk) is released if the connection drops, if
  the host goes quiet for 6s, or when the host switches away.
- Receivers need only Accessibility; they never read the remote.

Set up on each Mac under 设置 › 多电脑: pick a role, a short name, and the same
passcode everywhere. Built on another Mac, the app is not signed by an identity that
Mac trusts, so open it the first time with right-click → Open.

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
