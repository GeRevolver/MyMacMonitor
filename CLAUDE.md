# CLAUDE.md — M9 Volume

A macOS menu-bar agent that controls a **Samsung Smart Monitor M9** volume from the
Mac by forwarding the keyboard's volume/mute keys over the monitor's Wi-Fi remote.

## Why this exists (don't re-derive these — they were proven empirically)

- Samsung Smart Monitors run **Tizen** and do **not** support DDC/CI, so MonitorControl /
  BetterDisplay-style brightness/volume protocols can't see them. Control happens over
  the **Samsung WebSocket remote** (same API as Samsung TVs), exactly like DisplayBuddy.
- **WebSocket remote** (this is what we use):
  - `wss://<IP>:8002/api/v2/channels/samsung.remote.control?name=<base64-name>&token=<token>`
  - The monitor presents a **self-signed TLS cert** — trust it in the URLSession auth
    challenge (`URLCredential(trust:)`). Do not try to validate it.
  - First connect with no token → monitor shows an **Allow** dialog → the granted token
    arrives in an `ms.channel.connect` event → persist it to `~/.m9volume_token` and reuse.
  - Keys are **relative only**: `KEY_VOLUP`, `KEY_VOLDOWN`, `KEY_MUTE` (mute is a toggle).
    Send via JSON: `{"method":"ms.remote.control","params":{"Cmd":"Click",
    "DataOfCmd":"KEY_VOLUP","Option":"false","TypeOfRemote":"SendRemoteKey"}}`
  - "Force unmute" = `KEY_VOLUP` then `KEY_VOLDOWN` (net-zero), because mute is only a toggle
    and the mute state can't be read locally.
- **UPnP RenderingControl is a dead end.** The M9 advertises a MediaRenderer at
  `http://<IP>:9197/dmr` with a standard-looking RenderingControl SCPD (GetVolume/SetVolume,
  Channel=Master, Volume 0–100), but every call returns **HTTP 400 / UPnPError 402 "Invalid
  Args"** even with the documented arguments. It's a non-functional stub. Do NOT use UPnP for
  volume. (This is why there's no absolute 0–100 slider.)
- **SmartThings** would give absolute volume (`audioVolume` capability) but Personal Access
  Tokens now expire in ~24h → would require full OAuth. Not used.

## Device specifics (this user's unit)

- Model: `<MODEL_ID>` (internal `<INTERNAL_ID>`), 32" Smart Monitor M9, Tizen.
- Current IP: `192.168.1.x` (DHCP — app auto-discovers, don't hardcode).
- wifiMac: `XX:XX:XX:XX:XX:XX` (useful for a DHCP reservation or Wake-on-LAN).

## Architecture (`Sources/main.swift`, single file)

- `M9Remote` — WebSocket client + discovery + reconnect + key sending.
  - Discovery: try the saved IP (`UserDefaults` `m9_last_ip`); else sweep the local /24
    (subnet from `getifaddrs` on en0/en1) hitting `:8001/api/v2/` and matching modelName
    containing "M9". Re-sweeps automatically if reconnects keep failing (IP changed).
  - Reconnect: proactive with exponential backoff (1→10s), reconnect on
    `NSWorkspace.didWakeNotification`, re-discover after repeated failures.
- `mediaKeyCallback` — a `@convention(c)` CGEventTap callback on `NSSystemDefined` (type 14),
  subtype 8; keyCodes 0/1/7 = volume up/down/mute; swallows the event (returns nil) so the
  Mac doesn't also react.
- `AppDelegate` — `NSStatusItem` menu (status+IP, Forward-keys toggle, Launch-at-Login,
  Vol/Mute/Unmute, Rescan, Quit), creates/enables the tap, prompts for Accessibility.

## Build constraints (critical — easy to break)

- **App Sandbox must be OFF** — a sandboxed app cannot create a global event tap.
  (project.yml declares no entitlements file → sandbox off. Don't add the capability.)
- **LSUIElement = YES** — menu-bar agent, no Dock icon / window. (Set in project.yml; the
  code also calls `setActivationPolicy(.accessory)`.)
- **ATS `NSAllowsArbitraryLoads`** — needed once bundled, for the plain-http discovery and the
  self-signed wss. (In project.yml.)
- **Accessibility permission** — required at runtime for key capture (`AXIsProcessTrusted`).
  The app prompts and auto-activates the tap within ~2s of being granted.
- **ServiceManagement** (`SMAppService.mainApp`) for Launch-at-Login — only works when running
  as a real `.app` bundle (ideally from `/Applications`, not the DerivedData build).
- Deployment target **macOS 13+** (SMAppService).

## Build / run

```
brew install xcodegen          # one time
xcodegen generate              # makes M9Volume.xcodeproj from project.yml
open M9Volume.xcodeproj        # then set Signing > Team, and Cmd+R
```
Or skip Xcode and produce a signed app in /Applications with `./build.sh`.

For Launch-at-Login to be stable, run the app from `/Applications` (Cmd+R runs it from
DerivedData, which is fine for development but a transient path for the login item).

## Conventions

- Surgical changes; minimum code; no speculative features or abstractions.
- State assumptions and tradeoffs; if a simpler approach exists, say so.
- Verify by compiling (`xcodebuild -scheme M9Volume build` or `swiftc Sources/main.swift
  -o /tmp/m9 -framework Cocoa`) before declaring something done — this is the one thing the
  chat assistant could not do, so prefer to actually build here.
- Success criteria: keyboard volume keys change the M9's volume; menu Unmute works; the app
  reconnects after the monitor sleeps/wakes; Launch-at-Login keeps it running.
```
