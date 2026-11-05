# CLAUDE.md — MyMacMonitor

A macOS menu-bar agent that forwards the keyboard's volume/mute keys to a **Samsung Smart
Monitor M9** over the monitor's Wi-Fi remote. Security-hardened fork of `omarozt/M9Volume`
(audited at `496855f`). Read [SECURITY-AUDIT.md](SECURITY-AUDIT.md) before changing anything
security-relevant.

## Security invariants (do not regress)

1. **Event tap = media keys only.** Mask is `NSSystemDefined` (type 14). Never add `keyDown`
   or other keyboard events; the app must not be able to observe typing.
2. **Swallow volume keys only while the M9 is the default output** (`defaultOutputIsM9()`:
   CoreAudio transport DisplayPort/HDMI + name contains "M9"). Otherwise pass events through.
   Keep the CoreAudio check behind the volume-keyCode test (never on every media key).
3. **TLS: trust-on-first-use pin.** Self-signed cert → no CA validation; pin SHA-256 of the
   leaf DER in `m9_cert_sha256`; only accept challenges for `host == ip && port == 8002`;
   refuse mismatches and surface `certMismatch`. Never revert to blanket `.useCredential`.
4. **Token file owner-only** (`0600`) at `~/.mymacmonitor_token`.
5. **Network scope:** `onHomeNetwork()` gates `start()`, `sweep()`, `connect()` and
   `wakeMonitor()`. Only the manual *Rescan* may re-home to a new subnet.
6. **ATS:** `NSAllowsLocalNetworking` only. Never `NSAllowsArbitraryLoads`.
7. **Auto-wake off by default.** No internet endpoints, no telemetry, ever.
8. **`KEY_POWER` is never queued or blind-sent** (toggle with unreadable state); see
   [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Architecture (`Sources/main.swift`, single file)

- `M9Remote`: discovery (`probe`, `sweep`, `localSubnetBase`), WebSocket connect/reconnect
  with backoff, key sending with a small pending queue, Wake-on-LAN + guarded power, TLS pin
  (`urlSession(_:didReceive:…)`), `resetPairing()`.
- `mediaKeyCallback` + `defaultOutputIsM9()`: C callback for the event tap; keyCodes 0/1/7 =
  volume up/down/mute, key-down state `0x0A`.
- `AppDelegate`: status-item menu (status line incl. "not on the monitor's network" /
  "certificate changed!", Forward-keys toggle, volume/mute, OK/Back/Home/Power click items,
  Rescan, Reset pairing…, Settings…, About, Quit), Settings window (Forward keys, Auto-wake,
  Launch at Login), Accessibility prompt + self-relaunch on grant.

`UserDefaults` keys: `m9_last_ip`, `m9_home_subnet`, `m9_cert_sha256`, `m9_wifi_mac`,
`m9_autowake` (default false), `m9_forward_keys` (default true). Key names kept from upstream
for compatibility.

## Build constraints

- **App Sandbox OFF** (global event tap); **hardened runtime ON**; `LSUIElement` = YES.
- **Accessibility** required at runtime; ad-hoc signature changes on every rebuild → re-grant.
- Build output must live **outside iCloud-synced folders** (xattrs break the signature).
- macOS 13+ (`SMAppService`), arm64.

## Build / run

```
./build.sh       # swiftc → ~/Library/Caches/MyMacMonitor-build/MyMacMonitor.app (no install)
./install.sh     # explicit: copy to /Applications and open
swift tools/make-icon.swift   # regenerate Resources/AppIcon.icns (no SF Symbols in icons)
```

## Conventions

- Surgical changes; minimum code; every security-relevant change documented in
  SECURITY-AUDIT.md (before/after + verification).
- Verify by compiling (`./build.sh`) and, for behaviour, on real hardware.
- Commits use the GitHub noreply address; never commit tokens, IPs, MACs or cert fingerprints.
