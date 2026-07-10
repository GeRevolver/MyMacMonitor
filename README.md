# M9 Volume

A macOS menu-bar app that controls a **Samsung Smart Monitor M9** from the Mac keyboard —
volume, mute, power, and full remote navigation — over the monitor's Wi-Fi remote protocol.

Samsung Smart Monitors run Tizen and don't support DDC/CI, so tools like MonitorControl or
BetterDisplay can't see them and the Mac's volume keys do nothing. This app forwards those
keys over the same WebSocket remote API a Samsung TV uses, and adds the parts a monitor-as-
Mac-display actually needs: waking it when you sit down, and driving its Tizen UI without
hunting for the physical remote.

## Features

- **Volume keys just work** — the keyboard's volume up/down/mute keys control the M9
  (the Mac-side event is swallowed so nothing double-triggers).
- **Auto-wake** — when the Mac wakes, or the displays wake after idle, the monitor is
  powered on automatically (Wake-on-LAN plus a state-guarded power key). It only acts at
  wake transitions — the monitor still sleeps normally.
- **Remote navigation from the keyboard**:

  | Shortcut | Action |
  |---|---|
  | ⌃⌥ ← ↑ ↓ → | Navigate |
  | ⌃⌥ ↩ | OK / Select |
  | ⌃⌥ ⌫ | Back |
  | ⌃⌥ H | Home |
  | ⌃⌥ P | Monitor power (smart toggle) |
  | ⌃⌥ R | Toggle Remote Mode |

- **Remote Mode** (⌃⌥R) — the menu-bar icon becomes a remote glyph and bare
  **arrows / Return / Esc** drive the monitor directly; everything else types normally.
  Toggle again to exit.
- **Settings window** — connection status, monitor MAC, rescan, and toggles for key
  forwarding, auto-wake, and Launch at Login. **About** panel lists the shortcuts.
- **Zero configuration** — finds the monitor by sweeping the local /24, remembers its IP
  and MAC, reconnects with backoff after monitor/Mac sleep, re-discovers after DHCP
  changes, and persists the pairing token (`~/.m9volume_token`).

## Requirements

- macOS 13+ (Ventura or later).
- The M9 on the same network/subnet as the Mac.
- **Accessibility permission** (to capture the keyboard keys) — the app prompts on first
  launch and relaunches itself once granted.
- For auto-wake: the monitor setting **Settings > General > Network > Expert Settings >
  "Power On with Mobile"** must be ON. Without it the monitor drops into deep standby
  where no software can wake it.

## Build & install

The short way — builds a signed `M9Volume.app` straight into `/Applications`:

```sh
./build.sh
```

Or manually via Xcode:

```sh
brew install xcodegen        # one time
xcodegen generate            # creates M9Volume.xcodeproj from project.yml
open M9Volume.xcodeproj      # set Signing > Team, then build
```

Quick syntax check without Xcode: `swiftc Sources/main.swift -o /tmp/m9 -framework Cocoa`.

**Step-by-step instructions** (monitor settings, permissions, pairing, deep
troubleshooting): see the **[Setup Guide](docs/SETUP.md)**.

Run the built `M9Volume.app` from **/Applications** — Launch at Login (SMAppService) needs
a stable path, and Accessibility permission sticks to the signing identity, so set a real
Team before building.

On first connection the monitor shows an **Allow** dialog — accept it once; the granted
token is stored and reused.

## Troubleshooting

- **"M9 — searching…" forever** — the monitor must be on the same /24 subnet; try
  *Rescan for monitor*; check it's on Wi-Fi at all.
- **Auto-wake does nothing** — enable "Power On with Mobile" on the monitor (see above).
- **Hotkeys don't respond** — grant Accessibility (System Settings > Privacy & Security);
  note hotkeys are inert inside secure-input fields (password prompts) by macOS design.
- **Power key seems ignored while disconnected** — powering the monitor *off* requires a
  live connection; the app never blind-fires the power toggle (it's a toggle, and firing
  it late would turn a freshly-woken monitor back off).

## How it works

The M9 exposes the Samsung TV remote WebSocket on `wss://<ip>:8002` (self-signed cert,
token auth) and a device-info endpoint on `http://<ip>:8001/api/v2/` that reports
`PowerState` and `wifiMac`. Keys are relative-only (`KEY_VOLUP`, `KEY_MUTE`, …); volume
capture uses a CGEventTap on the system media keys. Waking uses a WoL magic packet first,
then `KEY_POWER` only when the monitor verifiably reports `standby`. UPnP RenderingControl
looks available on this hardware but is a non-functional stub.

Full protocol details — endpoints, payloads, key semantics, Wake-on-LAN, discovery, and
the dead ends so you don't repeat them — are in
**[docs/PROTOCOL.md](docs/PROTOCOL.md)**; architecture and build constraints (sandbox must
stay off, etc.) are in `CLAUDE.md`.

Everything lives in one file: `Sources/main.swift`.

## License

[MIT](LICENSE)
