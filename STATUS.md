# STATUS — snapshot for session continuation

_Last updated: 2026-07-10. Update this file whenever a session materially changes the repo._

## Where things stand

- Branch `main`, **committed and pushed** to `github.com/omarozt/M9Volume` (private repo).
  The 2026-07-05 feature set (auto-wake, ⌃⌥ hotkeys, Remote Mode, Settings/About/icon)
  plus the 2026-07-10 polish pass are all in.
- Repo hygiene done: `M9Volume.xcodeproj` is generated + gitignored (untracked along with
  `.DS_Store`/`xcuserstate`); source dir renamed `sources/` → `Sources/` (matches
  project.yml/docs); `build.sh` now actually exists (auto-detects signing team, installs
  to /Applications).
- Docs: README polished; `docs/SETUP.md` (end-user guide) and `docs/PROTOCOL.md`
  (protocol reference) added; MIT `LICENSE` added.
- Sanitization: **complete, including history.** 2026-07-10 `git filter-repo` rewrite
  scrubbed the monitor MAC/IP/model ids and both team ids from every commit, dropped the
  ever-tracked `.xcodeproj`/`.DS_Store` blobs, and switched commit emails to the GitHub
  noreply address; force-pushed. All commit hashes changed. The team id still lives in
  the local *untracked* `.xcodeproj` (harmless). Safe to make public from a
  leak standpoint.

## Verification state

- ✅ Compiles clean (`swiftc Sources/main.swift`), full `xcodebuild` app build succeeds.
- ✅ Two adversarial review rounds on the feature set (2026-07-05); all confirmed
  findings fixed — see SESSION-LOG.md.
- ❌ **NOT yet tested on hardware.** Pending manual checklist:
  1. Volume/mute keys still work (regression).
  2. `defaults read com.omer.m9volume m9_wifi_mac` shows the MAC after discovery.
  3. ⌃⌥ nav hotkeys work, incl. with "Forward volume keys" off; ⌃⌥⇧ combos pass through.
  4. Remote Mode: icon swap, bare-key nav, exits with ⌃⌥R, off after relaunch.
  5. Auto-wake: sleep Mac → wake → monitor on within seconds; displays-idle → key press →
     monitor on; toggle off → nothing; monitor already on → no spurious toggle.
  6. Settings window sync both directions; About panel; Launch at Login from /Applications.
  7. `./build.sh` end-to-end (team auto-detect, install, relaunch, permissions persist).

## User actions required (blockers for testing)

- On the monitor: **Settings > General > Network > Expert Settings > "Power On with
  Mobile" = ON** (auto-wake is impossible from deep standby without it).
- Signing: either run `./build.sh` (auto-detects the team) or set Signing > Team in Xcode
  after `xcodegen generate`.

## Known/accepted limitations

- Powering the monitor **off** needs a live WS; during a transient disconnect ⌃⌥P probes,
  sees "on", and deliberately does nothing (never blind-toggle).
- Hotkeys are inert in secure-input contexts (password fields) — macOS behavior.

## Next-step candidates (not started)

- Hardware test pass (checklist above), then fix whatever it surfaces.
- Optional: manual IP field in Settings; a real `.icns` app icon; make the repo public
  (consider history rewrite for the team id first).
