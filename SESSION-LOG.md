# SESSION LOG

Chronological record of working sessions. Newest first. Keep entries factual and short;
STATUS.md carries the current state, this file carries the why/how history.

## 2026-07-10 — Publish: hygiene, guides, build.sh, commit + push

**Goal:** get the (previously all-uncommitted) working tree onto GitHub, polished.

- Confirmed the `origin` remote (`github.com/omarozt/M9Volume`) exists and is **private**
  (unauthenticated API 404s; git credentials work). Pushed without needing `gh` auth.
- Hygiene: untracked `M9Volume.xcodeproj` (it's xcodegen-generated; also removes the
  DEVELOPMENT_TEAM id and `xcuserstate` churn from tracking), untracked `.DS_Store`;
  renamed `sources/` → `Sources/` (two-step `git mv`, case-insensitive APFS).
- Wrote the previously-missing `build.sh`: xcodegen → xcodebuild Release with the team
  auto-detected from the keychain (`DEVELOPMENT_TEAM` env overrides; ad-hoc fallback with
  a warning) → `ditto` into /Applications → relaunch.
- Docs: `docs/SETUP.md` (end-user guide incl. deep troubleshooting + `defaults` keys) and
  `docs/PROTOCOL.md` (protocol reference incl. dead ends), drafted by an Opus subagent
  from CLAUDE.md/SESSION-LOG and cross-checked against main.swift; README build section
  reworked around `./build.sh` + links to both; MIT `LICENSE`.
- Fixed a lying comment: `modelKeyword` claimed to match `modelName`; it matches the raw
  :8001 body (hit is in `device.name`) — comment now says so.
- Note: STATUS.md previously claimed the team id was removed from `project.pbxproj`; it
  was actually still there. Moot now that the file is untracked, but the id remains in
  git history (`445e15c`) — rewrite before ever making the repo public if desired.

**State at session end:** committed & pushed; compiles + full xcodebuild verified;
hardware testing still pending (checklist in STATUS.md).

## 2026-07-05 — Auto-wake, nav hotkeys, Remote Mode, Settings/About/icon

**Problem:** every time the Mac wakes, the M9 stays in standby and the physical remote is
needed to power it on; the remote's nav cluster (arrows/OK) wasn't reachable from the
keyboard at all.

**Decisions (agreed with user):**
- Wake the monitor at *interaction transitions* (Mac wake + displays-wake-after-idle),
  never keep it awake. Menu/Settings toggle, default ON.
- Both shortcut styles: always-on ⌃⌥ hotkeys **and** a toggleable Remote Mode.
- Extra keys: Back (`KEY_RETURN`) and Home (`KEY_HOME`).
- Icon: `tv.and.hifispeaker.fill` normal / `av.remote.fill` in Remote Mode.
- Launch-at-Login + Auto-wake live in the new Settings window, not the menu.

**Protocol facts established (via samsungtvws / Home Assistant / homebridge-tizen):**
- `:8001/api/v2/` reports `device.PowerState` + `device.wifiMac`, but only in *network
  standby* — which requires the monitor's "Power On with Mobile" setting. Deep standby =
  NIC off = WoL magic packet is the only lever.
- `KEY_POWER` is a toggle (`KEY_POWEROFF` == `KEY_POWER` on recent Tizen); never blind-send.
- WoL: send to both `255.255.255.255` and `<subnet>.255` (APs often drop the global one).
- The M9's `modelName` is a sales code that does NOT contain "M9" — identity matching must
  stay on the raw response body (the hit is in `device.name`). Do not "fix" this.

**Adversarial review round 1 (3 finder dimensions × 3 skeptic votes) — confirmed & fixed:**
1. *major* — The HTTP probe (ms) always beats the WS handshake (TLS+upgrade+
   `ms.channel.connect`), so `standby` was observed while `connected==false`, the guarded
   KEY_POWER was silently dropped, and the wake sequence terminated. Fix: standby-without-
   socket now calls `connect()` and retries until the deadline.
2. *major* — `attemptWake(ip: nil)` (app launched while monitor dark) fired one WoL and
   gave up; discovery was never restarted. Fix: coalesce `ip ?? self.ip`, kick `start()`,
   retry to deadline.
3. *minor* — ⌃⌥ hotkey gate didn't exclude ⇧ (swallowed ⌃⌥⇧-combos globally). Fix: exact
   intersection match.
4. *minor* — `wifiMac` written on the URLSession queue, read on main. Fix: write on main.
- Rejected as designed-behavior: power-off requiring a live WS (documented in CLAUDE.md
  instead — the "fix" would reintroduce the stale-toggle hazard).

**UI round review (1 reviewer) — confirmed & fixed:** Settings' Forward-keys checkbox
missed the Accessibility gate the menu applies (surfaces could disagree pre-grant).
Reviewer empirically verified the Settings window layout (360×336, no constraint
conflicts, no menu↔settings refresh recursion).

**Invariants introduced (do not break):**
- `KEY_POWER` never enters the pending-key queue; sent only over a live socket, only when
  a probe explicitly returned `standby` (auto path), or on explicit user toggle while
  connected.
- The event tap stays enabled once created; `forwardingEnabled` gates only the media-key
  branch.
- Auto-wake acts only at wake transitions; no power assertions anywhere.

**State at session end:** compiles clean; everything uncommitted; hardware untested.
See STATUS.md.

## Earlier (committed history)

- `9cd5c43` — initial implementation: volume/mute forwarding via CGEventTap +
  Samsung WS remote, /24 discovery, reconnect w/ backoff, Launch-at-Login, menu bar UI.
- `01ea353` — project settings + Accessibility permission handling (relaunch-on-grant).
- `445e15c` — DEVELOPMENT_TEAM pinned for stable signing (later reverted in the working
  tree during sanitization).
