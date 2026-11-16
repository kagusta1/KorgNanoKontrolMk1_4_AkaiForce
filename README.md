# Korg nanoKONTROL (Mk1) script for Akai Force / MPC 3

A device script that maps a Korg nanoKONTROL Mk1 to track mixing, mute, cue, transport and view switching on an Akai Force running the MPC 3 software.

## Files

| File | Purpose |
|---|---|
| `nanoKontrol.ini` | Tells MPC which MIDI port belongs to the device and which script to load. Checksum generated with 'sign_script.py' against the MPC bin file of 3.10.0.49. Tested on Akai Force 3.10.1.12 |
| `nanoKontrol.lua` | The script: registers the CCs on load and handles them |

Install both files where MPC loads its device scripts (next to the other `.ini` / `.lua` pairs).

## How it works

- `OnLoad` runs when the device **connects**, not when the script is evaluated. If the `.ini` port name does not match a port MPC has created, the script loads but `OnLoad` never fires.
- MPC matches ports by the name of **its own ALSA sequencer client**, which can differ from the USB product name and from the raw `amidi -l` name. On the Force the nanoKONTROL appears as `nanoKONTROL _ CTRL`:

  ```
  input=nanoKONTROL _ CTRL
  output=nanoKONTROL _ CTRL
  ```

  To check the name on your unit: `cat /proc/asound/seq/clients` (client `MPC 3`, port list).
- All the handler functions MPC expects (`HandleMIDINoteOn`, `HandleMIDINoteOff`, `HandleMIDICC`, `HandleMIDISysex`, `HandleTimer`, `OnLoad`, `OnUnload`) are defined. Only `HandleMIDICC` does work.
- `OnLoad` is guarded so a repeated call cannot register the CCs twice.

## Mapping (MIDI channel 0)

| CC | Function | Implementation |
|---|---|---|
| 2–10 | Track volume 1–9 | `track.Volume.value` (0–127 scaled to 0–1) |
| 11–19 | Track pan 1–9 | `track.Pan.value` |
| 20–28 | Mute track 1–9 | `track.SetMute(not track.Mute.value)` |
| 29–37 | Cue track 1–9 | Emulated Force buttons: SOLO, the track's `trackAssign` button, then Rec Arm |
| 38 | Playhead to start | `mpc.sequencer.JumpToPulse(0)` (also works during playback) |
| 39 | Play | `TogglePlay`, only if `mpc.sequencer.Playing.value` is false |
| 40 | Redo | `mpc.commandManager.Redo()` |
| 41 | Arranger → Grid → Clip Editor → List Edit → … | `mpc.engineMode.RequestModeChange(name)`, one step per press |
| 42 | Double press on Stop | `mpc.force.stop.DoublePress()` |
| 43 | Sampler | `mpc.engineMode.RequestModeChange(name)` |

Each mute or cue message is one toggle, regardless of the CC value (0 or 127). The track state is read each time, so it stays correct if a track is changed by hand on the Force. CC38–CC43 act on press only (value > 0), so set them to **momentary** in the Korg Kontrol Editor. Set the mute and cue buttons to **toggle** if you want their LEDs to follow the button state.

## Configuration

At the top of `nanoKontrol.lua`:

| Setting | Meaning |
|---|---|
| `midiChannel` | MIDI channel the nanoKONTROL sends on (0-based) |
| `…CCStart` / `…CCEnd`, `toStartCC`, `playCC`, … | CC numbers for each group or button |
| `soloMode` | `"emulate"` presses the Force's own buttons (needed for **CUE tracks** mode); `"property"` sets `track.Solo` directly (only works in **solo tracks** mode) |
| `cueButtonPrefix` | Force button row pressed for cue / mute emulation: `"trackAssign"` or `"trackSelect"` |
| `restoreMode` | Lower-row mode to return to after a cue press: `"recArm"`, `"mute"`, `"clipStop"` or `nil` |
| `muteMode` | `"property"` (default, leaves the Force's lower-row mode alone) or `"emulate"` |
| `samplerModeNames`, `arrangeViews` | Engine mode names tried, in order, for CC43 and CC41 |
| `enableProbes`, `logMonitor`, `probeCC` | Diagnostics, off by default |

The Force's own SOLO button preference ("solo tracks" or "CUE tracks") is a device setting the script cannot change. With `soloMode = "emulate"` the cue buttons work in "CUE tracks" mode.

## Debugging

`print` output goes to the system journal of the MPC service:

```
journalctl -u acvs -f -o cat --no-pager | grep NanoKontrol
```

Every script message starts with `NanoKontrol:` so it can be filtered. Redirect to a file (`> /data/nano.log`) for long output, since terminals wrap long lines.

## Notes on the MPC scripting API

Findings from the Akai and ForceLink reference scripts and from probing the Force. Names and behaviour may differ between firmware versions.

- **Per-track state lives on `mpc.tracks.normalTracks[i]`**: `Volume`, `Pan`, `Mute`, `Solo`, `RecArm`, `Send1`–`Send4`, with matching `Get…` / `Set…` functions. The same function names on `mpc.tracks` itself fail when called from a script.
- **There is no scriptable cue.** `track.Solo` only has an effect when the Force's SOLO button is in "solo tracks" mode. Cue is reached by emulating the hardware buttons.
- **`mpc.force.<button>` objects emulate hardware buttons** with `Press`, `Release`, `Hold` and `DoublePress`. Pressing them changes the Force's state (for example, SOLO puts the lower button row into solo/cue mode). The script cannot read that state, so it returns to a fixed mode (`restoreMode`).
- **Views are engine modes.** `mpc.engineMode.RequestModeChange(name)` switches them, `mpc.engineMode.CurrentMode.value` reads the current one, and `mpc.engineMode.GetAvailableModes()` lists them. The names are not documented and follow the menu labels (for example "Clip Editor", "List Edit"). Log the available modes to find them on your firmware.
- **The current view is detected by exact mode name.** A keyword fallback skips any mode whose name contains "matrix".
- **`mpc.sequencer`** provides `TogglePlay`, `TogglePlayStart`, `Stop`, `JumpToPulse(pulse)` and the `Playing` property. `mpc.commandManager` provides `Undo` and `Redo`.
- **`GetTrackMonitorState` / `SetTrackMonitorState` on `mpc.tracks` cannot be called from a script** in any form tried (with or without `self`, 0- or 1-based index). `track.GetState` does not exist.
- **Probing technique:** iterate an object with `pairs` and print one line per member, then read the journal. This is how every API name above was confirmed.
