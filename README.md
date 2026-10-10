# AppMixer — per-app volume mixer for macOS

Native Swift menu-bar app. One slider per audible app, mute, live meters,
master volume, output picker, auto-ducking on calls, persisted levels.
Built on Apple's Core Audio Process Tap API (`CATapDescription`,
`AudioHardwareCreateProcessTap`) — no kernel extensions, no virtual drivers.

- Requires macOS 14.2+ (tested on macOS 26/27; universal binary: Apple Silicon + Intel).
- Non-sandboxed (process taps are unavailable to sandboxed apps).
- First launch prompts for **Screen & System Audio Recording** (`NSAudioCaptureUsageDescription`).
  Audio is mixed locally; nothing is recorded or sent anywhere.

## How it works

1. `ProcessDetector` polls `kAudioHardwarePropertyProcessObjectList` +
   `kAudioProcessPropertyIsRunningOutput` (1 Hz + HAL listener).
2. `TapEngine` creates one `CATapMutedWhenTapped` tap per audible app.
   Tapped audio is silenced on its direct path and re-played by us —
   quit/crash/stall and macOS un-mutes the app (crash-safe).
3. Each tap lives in its own private tap-only aggregate (drift compensation on,
   no output subdevice — Bluetooth HFP safe).
4. A tap IOProc applies nothing but pushes raw stereo into a per-app ring
   and publishes a peak for meters (realtime thread: trylock only, no alloc).
5. One output IOProc on the real default device mixes rings **additively**
   into `outputData` with per-app gain (user × master × duck). Untapped apps
   flow through the system mix untouched.

## Build & run (Command Line Tools only, no full Xcode needed)

```sh
cd AppMixer
swift build
sh scripts/bundle-app.sh
open dist/AppMixer.app
```

Grant permission: System Settings → Privacy & Security →
Screen & System Audio Recording → enable AppMixer → relaunch.

Debug (detection only, no audio): run the binary from Terminal and watch
for error lines; play audio in two apps and check rows appear.

## Project layout

```
Package.swift
Info.plist                 # LSUIElement, NSAudioCaptureUsageDescription
Sources/AppMixer/
  AppMixerApp.swift        # MenuBarExtra entry
  Views.swift              # panel, rows, meters, master, picker
  AudioState.swift         # MainActor bridge (detector+engine -> UI)
  ProcessDetector.swift    # audible-app detection
  TapEngine.swift          # taps, aggregates, IOProcs, mixer, ducking
  Realtime.swift           # TapSlot + lock-free-ish stereo ring
  CoreAudioHelpers.swift   # HAL property helpers
scripts/bundle-app.sh      # wraps CLI binary into .app
```

## Limits / next steps

- Sample-rate mismatch between tap and output is not resampled yet (usually
  both 48 kHz; warning-free path). Headphone hot-swap restarts the output
  IOProc via default-device listener.
- Interleaved output devices take a chunked heap path; planar stereo (the
  common case) is allocation-free.
- For Developer ID distribution: sign, notarize, keep bundle ID stable
  (TCC is keyed by CDHash — same-ID reinstalls may need a permission toggle).

## License

MIT — see [LICENSE](LICENSE).
