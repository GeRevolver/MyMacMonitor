# STATUS — My MacMonitor

_Last updated: 2026-11-05._

## Where things stand

- Fork of `omarozt/M9Volume`, audited at `496855f`; work lives on branch `hardened`.
- Security hardening (10 changes) + rebrand to **My MacMonitor** (name, bundle id
  `io.github.gerevolver.mymacmonitor`, custom icon, token path with migration).
- Dependency-free build (`build.sh`) and explicit install (`install.sh`).
- Docs: README, [SECURITY-AUDIT.md](SECURITY-AUDIT.md), docs/SETUP.md, docs/PROTOCOL.md.

## Verified on hardware (MacBook Air M3, macOS 27.2, Samsung M9 M90SF via USB-C)

- ✅ Pairing, discovery, single LAN connection only, cert pin matches, token `0600`.
- ✅ F10–F12 → monitor when it's the sound output; → Mac with built-in speakers.
- ✅ Idle cost ≈ 0 % CPU, ~33 MB RAM.

## Not yet exercised

- Foreign-network behaviour ("not on the monitor's network"), *Reset pairing…*,
  auto-wake, Launch at Login across reboots.

## Ideas (not started)

- Brightness: probe DDC/CI read-only first; otherwise software dimming (gamma) on F1/F2,
  which on OLED genuinely reduces emitted light.
