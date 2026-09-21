let defaultConfig = #"""
// siriremoted — Siri Remote (3rd gen) as a programmable keyboard.
// Edit and save; the daemon hot-reloads. Buttons:
//   ringUp ringDown ringLeft ringRight center back tv playPause mute volUp volDown siri
// Gestures per button:
//   "tap" "double" "triple" "hold" "hold2" "whileHeld"  plus  "repeat": true
// Actions:
//   a keystroke   -> "up", "ctrl+tab", "cmd+shift+p", "pageup", "escape"
//   layer control -> "layer:next", "layer:prev", "layer:0", "layer:base",
//                    "layerMomentary:1"   (use with "whileHeld")
//   nothing       -> omit the button, or "none"

{
  "settings": {
    "doubleTapWindowMs": 280,   // lower = snappier taps, harder double-taps
    "holdThresholdMs": 350,
    "hold2ThresholdMs": 900,
    "repeatDelayMs": 350,       // how long before a held arrow starts repeating
    "repeatIntervalMs": 60,
    "layerChangeSound": true,
    "maxHeldKeySeconds": 120
  },

  "layers": [
    {
      "name": "base",
      "bindings": {
        // Thumb reaches these without moving the hand — keep them hot.
        "ringUp":    { "tap": "up",    "repeat": true },
        "ringDown":  { "tap": "down",  "repeat": true },
        "ringLeft":  { "tap": "left",  "repeat": true },
        "ringRight": { "tap": "right", "repeat": true },
        "center":    { "tap": "return" },

        "back":      { "tap": "escape" },

        // TV is intentionally unbound — reserved for chords. When you want it,
        // make it a momentary layer shift:
        //   "tv": { "whileHeld": "layerMomentary:1" }

        "playPause": { "tap": "layer:next" },
        "mute":      { "tap": "ctrl+tab" },

        "volUp":     { "tap": "pageup",   "repeat": true },
        "volDown":   { "tap": "pagedown", "repeat": true },

        // Hold to talk. Wispr Flow already binds right Option (keycode 61) to
        // push-to-talk, so we just hold it for as long as the button is down.
        // To switch to a dedicated key: add F18 as a PTT shortcut in Wispr's
        // settings, then change this to "f18".
        "siri":      { "whileHeld": "rightoption" }
      }
    },

    {
      // Layer 1 is a placeholder. playPause cycles into it; fill it in and
      // anything left undefined falls through to base.
      "name": "layer1",
      "fallthroughToBase": true,
      "bindings": {
        "playPause": { "tap": "layer:next" }
      }
    }
  ]
}
"""#
