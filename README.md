# HomeBar

A macOS menu bar app that controls your SmartRent thermostat, door lock, and lights,
and Philips Hue lights.

Works with SmartRent accounts. Not affiliated with SmartRent.

Developing HomeBar? Start with [AGENTS.md](AGENTS.md).

## Why it uses the cloud, not local Wi-Fi

The thermostat talks to the SmartRent hub over Z-Wave radio, not Wi-Fi. The hub
belongs to the property and accepts commands only from the SmartRent cloud.
So the app signs in with **your own resident account** and sends commands the
same way the official app does. Because of this, your Mac can be on any network,
including 5 GHz or away from home.

## Quick start

```bash
./scripts/build-app.sh                 # builds build/HomeBar.app and build/homebar-cli
open build/HomeBar.app --args --mock   # try the interface with fake devices
open build/HomeBar.app                 # sign in with your SmartRent account
```

### Phase 0 check (do this first with your real account)

```bash
build/homebar-cli login     # or sign in from the menu bar panel
build/homebar-cli devices   # must list your home and your thermostat
build/homebar-cli status    # read-only: shows temperature, mode, set points
build/homebar-cli watch     # live updates; change the set point in the SmartRent app to see them
build/homebar-cli heat 68   # sends a change and waits for the thermostat to confirm
```

If `devices` fails, the guessed parts of the protocol need a fix. See
[docs/protocol.md](docs/protocol.md).

## Layout

| Module | Contents |
|---|---|
| `Core` | Models, `HomeProvider` protocol, `HomeStore` (optimistic updates, undo after 10 s), `MockProvider` |
| `SmartRentProvider` | Login and token refresh, REST client, Phoenix websocket with heartbeat and reconnect (1 s … 60 s) |
| `Platform` | `KeychainStore` (this Mac only, no iCloud sync) |
| `UI` | Panel, climate card, vent air-flow animation, sign-in |
| `HomeBarApp` | `MenuBarExtra`, no Dock icon, reconnect on wake and on network change |
| `HomeBarCLI` | `homebar-cli` |

```bash
swift test                                        # 14 tests
swift run HomeBar --snapshot /tmp/panel.png       # renders the panel with fake devices
```

## Security

- The password is sent only to SmartRent at sign-in. It is never saved. Only the
  session tokens go in the Keychain.
- No tokens, passwords, or codes go to logs or error messages.
- The app opens no listening ports.

## The panel

Black and white, with colour only where it means something: heat (orange), cooling
(blue), the lock state (green or orange), the connection dot, and alerts.

- **Climate**: drag a knob around the dial (a trackpad tick for each degree), use − / +,
  or the arrow keys. Auto mode has a heat knob and a cool knob that stay 2° apart.
  Air streaks from the vent show what the system is doing now, and every set point
  change blows a gust out of the vent, warm or cool.
- **Fan**: Auto or On. These are the only fan settings the thermostat supports.
- **Door**: a thumb-turn. Lock is one click: the knob turns to horizontal and snaps in with a green ripple.
  Unlock asks for Touch ID or your Mac password every time and is never retried
  automatically: the knob turns back with an orange ripple. The knob
  turns fully only when the lock confirms; while a command waits, it leans toward the new position and the ring turns dashed.
- **Lights**: click a light tile to turn it on or off. Drag across a dimmable light to
  set its brightness; the fill follows the pointer. The palette button opens shades of
  white and colours.

## Philips Hue

Choose **… > Add Philips Hue…** in the panel footer. HomeBar looks for the bridge on
your network (or type its address, from the Hue app under Settings > My Hue System),
then asks you to press the round button on the bridge. The lights then appear next to
your SmartRent devices.

- HomeBar talks to the bridge directly on your network: no cloud and no Hue account.
- The bridge key stays in your Keychain. The bridge has a self-signed certificate, so
  HomeBar remembers it at pairing and afterwards refuses any other certificate.
- Only addresses on the local network are accepted (192.168.x.x, 10.x.x.x,
  172.16–31.x.x, and `.local` names).
- macOS asks once to let HomeBar use the local network. Allow it, or HomeBar cannot
  find the bridge.
- **… > Remove** forgets the bridge.

Try it without a bridge: `open build/HomeBar.app --args --mock --hue-unpaired --window`.

### Motion and Reduce Motion

The animations follow the system Reduce Motion setting: with it on, movement is
replaced by colour and glow changes. To see the full animations anyway, choose
**… > Full Animations** in the panel footer.

`open build/HomeBar.app --args --demo` runs fake devices in a window and plays the
animations on a loop (add `-fullAnimations YES` if Reduce Motion is on).

Design notes: motion follows the `apple-design` and `emil-design-eng` skills. Springs
with no overshoot for state changes, a bounce only where a physical part moves (the
lock knob), press feedback on every control, and no animation when the panel opens.

## Not built yet

SmartRent dimmer control, Hue rooms and scenes, door codes, notifications, the Settings window, start at
login, and Sparkle updates.
