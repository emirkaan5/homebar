# AGENTS.md

Guide for anyone (person or coding agent) working on HomeBar. Read this before you
change code. User-facing docs are in [README.md](README.md); protocol notes are in
[docs/protocol.md](docs/protocol.md).

## What this is

HomeBar is a macOS menu bar app (Swift 6, SwiftUI, macOS 14+) that controls a
resident's SmartRent devices (thermostat, door lock, switches, sensors) and
Philips Hue lights. It has no Dock icon. `homebar-cli` is a command-line client
that shares the same code.

- **SmartRent**: through the SmartRent cloud, with the resident's own account
  (the same login and websocket as the resident web dashboard). There is no local
  API: the devices are Z-Wave, behind a hub that belongs to the property.
- **Philips Hue**: directly to a Hue Bridge on the local network (CLIP API v2). No cloud.

## Commands

```bash
swift build                                    # debug build of everything
swift test                                     # all tests (Swift Testing); must pass before you finish
./scripts/build-app.sh                         # release build → build/HomeBar.app and build/homebar-cli
open build/HomeBar.app --args --mock           # fake devices, menu bar
open build/HomeBar.app --args --demo -fullAnimations YES   # fake devices in a window, animations on a loop
swift run HomeBar --snapshot /tmp/panel.png    # renders the panel with fake devices to PNG files, then quits
```

Launch options (handled in `Sources/HomeBarApp/HomeBarApp.swift`):

| Option | Effect |
|---|---|
| `--mock` | `MockProvider` + `MockLights` instead of real accounts |
| `--demo` | `--mock`, plus a window and a loop of lock, temperature, and light changes |
| `--window` | Also shows the panel in a normal window (for when the menu bar is hidden) |
| `--signed-out` | With `--mock`: start signed out, to try the sign-in form |
| `--hue-unpaired` | With `--mock`: no Hue bridge paired, to try the Hue setup |
| `--snapshot <path.png>` | Write PNG renders of several states, then quit |
| `-fullAnimations YES` | Play full motion even if the system Reduce Motion setting is on |

## Layout

```
Sources/
  Core/               Models, HomeProvider + AccessoryProvider protocols, HomeStore, CompositeProvider,
                      MockProvider, MockLights. No networking, no UI.
  SmartRentProvider/  SmartRent login, REST, Phoenix websocket, JSON mapping.
  HueProvider/        Hue Bridge discovery (Bonjour), pairing, certificate pinning, REST, event stream.
  Platform/           KeychainStore, BiometricGate (Touch ID).
  UI/                 All SwiftUI views. Depends only on Core.
  HomeBarApp/         App entry: MenuBarExtra, wiring, launch options, snapshot and demo modes.
  HomeBarCLI/         homebar-cli.
Tests/HomeBarTests/   Tests and JSON fixtures.
docs/protocol.md      What is known (and what is unverified) about each protocol.
scripts/build-app.sh  Builds and ad-hoc signs the .app, writes Info.plist.
```

## Architecture

```
Views (UI) ──read state / call──▶ HomeStore (@MainActor, @Observable) ──▶ any HomeProvider
                                                                         │
                                        CompositeProvider ◀──────────────┘
                                         ├─ primary: SmartRentProvider (or MockProvider)
                                         └─ accessories: [HueProvider (or MockLights)]
```

- **Views never touch the network.** They read `HomeStore` and call its methods.
- **Only a provider knows a vendor protocol.** To support a new system, write a provider;
  do not add vendor code to `Core` or `UI`.
  - A full account with sign-in and homes: conform to `HomeProvider`.
  - Extra devices next to the account (like Hue): conform to `AccessoryProvider`, and to
    `BridgeSetup` if it needs pairing. Add it to the `accessories` of `CompositeProvider`.
  - Prefix device IDs so `owns(_:)` can route commands (`hue:` for Hue).
- **Devices are generic.** A `Device` has a `kind` and string `attributes`. Typed views of
  the attributes (`Thermostat`, `DoorLock`, `LightState`) are computed properties in
  `Core/Models.swift`. Mappers must be tolerant: unknown or missing fields are normal.
- **Commands** are `DeviceCommand` cases. Each has an `AttributeChange` (name + value) and a
  `timing`: `.immediate`, `.debounce` (set points), or `.throttle` (brightness drags).
- **Optimistic updates.** `HomeStore.send` shows the change at once and marks it pending.
  A matching attribute event from the provider confirms it. With no confirmation in 10 s
  (30 s for locks), the store restores the last confirmed value, sets `errorMessage`, and
  increments `failures[device]` (the UI plays a failure animation on that).
- **Live updates** arrive as `AsyncStream<DeviceEvent>` from `updates(for:)`. While the user is
  still dragging or a debounce is waiting, incoming values for that attribute are kept aside
  so the control does not jump.

## Rules that must not be broken

Security and safety (this app controls a front door):

- **Unlock always goes through `HomeStore.setLocked(false, …)`, which asks the
  `ConfirmationGate` (Touch ID or the Mac password).** Never send `.setLocked(false, …)`
  any other way, never add a setting that skips the gate, and never retry an unlock automatically.
  `AllowGate` exists only for `--demo` with fake devices.
- **Never write passwords, tokens, Hue keys, or door codes to logs, errors, or the console.**
  Secrets live only in the Keychain (`KeychainStore`), with `ThisDeviceOnly` access, no iCloud sync.
  Passwords are never stored at all; only session tokens are.
- **Hue: only local hosts** (`HueMapper.isLocalHost`), and the bridge certificate is pinned
  at pairing (`HueTrust`). Do not relax either.
- **Do not try to control the SmartRent hub locally** (packet replay, LAN probing, the hub's
  own ports). It belongs to the property; it is not allowed and does not work. The old
  Python scripts in the parent folder tried this and are wrong; do not build on them.
- Test with `--mock` / `--demo` whenever possible. Do not lock, unlock, or change the real
  thermostat while testing unless the owner asked for that specific change.

Code:

- Swift 6 language mode with strict concurrency; keep the build free of warnings.
- `HomeStore` and all views are `@MainActor`. Providers are actors or `Sendable` structs.
- Use `JSONValue` (Core) for vendor JSON, not `[String: Any]`.
- Match the surrounding style: small types, comments that say *why*, plain English in
  user-facing text (short sentences, no jargon).

## Design system (UI)

The look follows two skills used during design: `apple-design` and `emil-design-eng`.

- **Black and white.** The page is pure black (dark mode) or pure white (light mode):
  `Palette.paper(scheme)`. Surfaces are `Palette.surface`, edges `Palette.hairline`.
  Selected controls are solid `Color.primary` with paper-coloured text.
- **Colour only where it means something**: heat `Palette.heat`, cooling `Palette.cool`,
  lock state `Palette.locked` / `Palette.unlocked`, failures `Palette.failure`, a light's own
  colour, the connection dot. Do not add decorative colour.
- **Motion values live in `Motion`** (`Theme.swift`): `press` for press feedback, `snappy`
  (critically damped spring) for state changes, `turn` for the lock knob, `tint` for colour
  changes. Reuse them; do not invent new curves in views.
- **Rules**: no animation when the panel opens (it opens many times a day); every pressable
  element gets press feedback (`PressableStyle`, `MonoButtonStyle`); bounce only where a
  physical part moves; never fade between two hues that pass through a muddy colour
  (switch under a covering element instead, as `LockGraphic` does).
- **Reduce Motion**: views read `@Environment(\.reducesMotion)` (not the system key
  directly). It follows the system setting unless the user chose *Full Animations*.
  With it on, replace movement with opacity/colour changes; do not just drop feedback.
- **Animations stop when the panel is closed** (`isPanelVisible` / `isActive`), to keep CPU
  near zero. `TimelineView` must not run when nothing moves.
- Tiles go in `TileRows`, which always fills the width.

## Verifying UI changes

- `swift run HomeBar --snapshot /tmp/panel.png` writes `/tmp/panel-*.png` (light, dark, auto
  mode, SmartRent-only, light controls, and `gallery`, the README hero). Look at them.
- README images live in `docs/screenshots/`. Regenerate them with `--snapshot` after UI
  changes. Use only demo devices in them: never a screenshot of a real home.
- `ImageRenderer` cannot draw AppKit-backed views: `ScrollView`, `Menu`, `TextField`,
  system `Picker`/`Button` styles. The panel has an `isSnapshot` path for this. Custom
  controls (`SegmentedPicker`, `MonoButtonStyle`) render fine.
- Snapshots cannot show motion. To check an animation, run `--demo -fullAnimations YES`,
  record with `screencapture -v -V 10 -R x,y,w,h out.mov`, and step through frames with
  `ffmpeg -i out.mov -vf "fps=30,crop=…,tile=…" sheet.png`.
- A `--window` or `--demo` window opens on whichever display is active. The owner may be
  using another display; prefer snapshots, and close test windows right away.

## Known gotchas

- **Keychain prompts after every rebuild.** The ad-hoc signature changes on each build,
  so macOS asks again before the new binary can read the saved session ("Always Allow").
  If the prompt cannot be shown (for example, the CLI run from a non-interactive shell),
  the read fails; the CLI reports this as a Keychain error.
- **The system Reduce Motion setting may be on.** If an animation "does nothing", check
  `defaults read com.apple.universalaccess reduceMotion` before debugging.
- **MenuBarExtra sizing.** The panel sizes itself to its content, and a bare `ScrollView`
  has no height of its own, so `PanelView` measures the list and sets the scroll height.
  `ViewThatFits` with a scroll fallback collapsed to zero height here; do not use it.
- **Local network permission.** Hue discovery needs `NSLocalNetworkUsageDescription` and
  `NSBonjourServices` in Info.plist (written by `scripts/build-app.sh`). `swift run` builds
  have no Info.plist, so test Hue discovery from `build/HomeBar.app`.
- **SmartRent hubs have no unit name**; the header shows "Home".
- **Unverified protocol details** are marked in `docs/protocol.md`. The Hue provider has only
  been tested against fixtures and `MockLights`, not a real bridge.

## Adding things

- **New device kind** (SmartRent): add the type mapping in `SmartRentProvider/DeviceMapper.kind`,
  a typed view in `Core/Models.swift`, commands in `DeviceCommand` (with `change` and `timing`),
  a view in `UI`, a case in `MockProvider`, and tests.
- **New command**: add the case, its `AttributeChange`, its `timing`, the provider's request
  body (`DeviceMapper.payload` / `HueMapper.body`), and a test of the encoded body.
- **Real protocol messages**: put redacted copies (no tokens, codes, names, or addresses) in
  `Tests/HomeBarTests/Fixtures` and test that they decode.

## Before you finish

1. `swift build` has no warnings, and `swift test` passes.
2. For UI changes: check the snapshots in light and dark mode.
3. Update README.md (user-facing behaviour), docs/protocol.md (protocol facts), and this file
   (architecture, rules, gotchas) when they change.
