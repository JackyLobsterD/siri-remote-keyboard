let defaultConfig = #"""
// siriremoted — Siri Remote (3rd gen) as a programmable keyboard.
// Edit and save; the daemon hot-reloads. The settings window edits this too.
//
// Buttons: ringUp ringDown ringLeft ringRight center back tv playPause mute
//          volUp volDown siri
// Gestures: "tap" "double" "triple" "hold" "hold2" "whileHeld" + "repeat": true,
//           and "sound" to play something when the button fires.
// Actions:  a keystroke        -> "up", "ctrl+a", "ctrl+end", "escape"
//           cycle layers       -> "layer:next" / "layer:prev"
//           jump to a layer    -> "layer:<name|index>"
//           hold for a layer   -> "layerMomentary:<name>"   (with "whileHeld")
//           leader             -> "layerOneShot:<name>"     (tap; next key uses it)
//           which Mac to drive -> "target:next" / "target:prev" / "target:local"

{
  "settings": {
    "doubleTapWindowMs": 280,
    "holdThresholdMs": 350,
    "hold2ThresholdMs": 900,
    "repeatDelayMs": 350,
    "repeatIntervalMs": 60,
    "oneShotTimeoutMs": 1500,
    "layerChangeSound": true,
    "maxHeldKeySeconds": 120
  },

  "layers": [
    {
      "name": "base",
      "bindings": {
        "ringUp":    { "tap": "up",    "repeat": true },
        "ringDown":  { "tap": "down",  "repeat": true },
        "ringLeft":  { "tap": "left",  "repeat": true },
        "ringRight": { "tap": "right", "repeat": true },
        "center":    { "tap": "return" },
        "back":      { "tap": "escape" },

        // Leader: tap TV, then press a direction within oneShotTimeoutMs.
        "tv":        { "tap": "layerOneShot:leader" },

        "playPause": { "tap": "layer:next" },
        "mute":      { "tap": "ctrl+tab" },
        "volUp":     { "tap": "pageup",   "repeat": true },
        "volDown":   { "tap": "pagedown", "repeat": true },

        // Hold to talk. Wispr Flow binds right Option (keycode 61) to push-to-talk.
        "siri":      { "whileHeld": "rightoption" }
      }
    },

    {
      // Reached only through the TV leader, never by cycling layers.
      "name": "leader",
      "skipInCycle": true,
      "fallthroughToBase": true,
      "bindings": {
        "ringLeft":  { "tap": "ctrl+a" },      // line start (terminal and text fields)
        "ringRight": { "tap": "ctrl+e" },      // line end
        "ringDown":  { "tap": "ctrl+end" },    // Claude Code: scroll to bottom
        "ringUp":    { "tap": "ctrl+home" },   // Claude Code: scroll to top
        "playPause": { "tap": "target:next" }  // next Mac (multi-Mac relay)
      }
    }
  ]
}
"""#
