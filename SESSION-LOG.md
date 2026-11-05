# SESSION LOG

Chronological record of working sessions. Newest first. Keep entries factual and short;
STATUS.md carries the current state, this file carries the why/how history.

## 2026-11-05 — Fork: security audit, hardening, rebrand to My MacMonitor (GeRevolver)

**Goal:** decide whether to trust the upstream app on a daily-driver Mac; keep the feature,
remove excess privilege.

- Read-only audit of `496855f` (code, history, author, permissions, network). Clean intent,
  but: global `keyDown` tap, unconditional swallow of volume keys, blanket TLS trust, `0644`
  token, sweeps on any network, weak identity check, global ATS opt-out, auto-wake default on.
- Hardened all of the above (see SECURITY-AUDIT.md for before/after) and removed the ⌃⌥
  hotkeys / Remote Mode (they required the `keyDown` tap).
- Rebrand: *My MacMonitor*, new bundle id and icon (drawn with Core Graphics, no SF Symbols),
  token moved to `~/.mymacmonitor_token` with one-time migration.
- Replaced the Homebrew/xcodegen build with `build.sh` (swiftc) + explicit `install.sh`; build
  output kept out of iCloud-synced folders (xattrs invalidated the signature).
- Verified on hardware: pairing, single LAN connection (`nettop`), pin == presented cert,
  token `0600`, key routing in both directions.

_Entries below are the upstream author's history._

## 2026-07-10 (later) — Security audit + history scrub (filter-repo, force-push)

**Goal:** audit for secrets/leaks, then obfuscate personal data.

- Audit: HEAD was clean, but pre-sanitization commits still carried the monitor Wi-Fi
  MAC, home LAN IP, unit model/internal ids, and **two** Apple team ids (pbxproj + an
  old project.yml); the ever-tracked `xcuserstate` binary leaked `/Users/omer/…` paths;
  commit metadata used the personal gmail. No credentials anywhere; the pairing token
  was never committed.
- Rewrote all history with `git filter-repo`: literal replacements for the six
  identifiers (`XX:…`/`<MODEL_ID>`-style placeholders), removed `M9Volume.xcodeproj/`
  and `.DS_Store` from every commit, author/committer email →
  `10370473+omarozt@users.noreply.github.com`. Verified zero hits across
  `git rev-list --all`; HEAD tree byte-identical. Force-pushed. **All commit hashes
  changed** — hashes in docs/memory from before this entry are historical labels only.
  A pre-rewrite backup bundle was kept in the session scratchpad (transient).
- Also fixed en route: the `sources/`→`Sources/` rename claimed by the earlier feature
  commit had been silently lost to a `git reset` on case-insensitive APFS; re-done as
  its own commit before the rewrite.
- Deliberately NOT done (out of scope, candidates below): `~/.m9volume_token` is
  written world-readable (`644`) — a `0600` chmod would be a two-line hardening.

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
  was actually still there. Moot now that the file is untracked. (History carried it
  until the same-day filter-repo rewrite — see the entry above.)

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

(Hashes below are post-rewrite — the 2026-07-10 filter-repo pass renumbered everything.)

- `62d3fd0` — initial implementation: volume/mute forwarding via CGEventTap +
  Samsung WS remote, /24 discovery, reconnect w/ backoff, Launch-at-Login, menu bar UI.
- `d48724b` — project settings + Accessibility permission handling (relaunch-on-grant).
- `1835211` — DEVELOPMENT_TEAM pinned for stable signing (later reverted in the working
  tree during sanitization).
