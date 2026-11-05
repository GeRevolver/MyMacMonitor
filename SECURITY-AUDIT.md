# Security Audit & Hardening — My MacMonitor

**Subject:** [`omarozt/M9Volume`](https://github.com/omarozt/M9Volume) at commit
[`496855f`](https://github.com/omarozt/M9Volume/tree/496855f14fc270a28b5a8b2f97388a977d32e608),
a macOS menu-bar app that forwards the keyboard's volume keys to a Samsung Smart Monitor M9.
**Result:** this fork, *My MacMonitor* (branch `hardened`).
**Date:** November 2026 · **Auditor:** Gerardo Espinosa ([@GeRevolver](https://github.com/GeRevolver))

---

## Why this audit exists

This was a **precautionary** review, not a response to an incident. The upstream code turned
out to be honest: no malware, no telemetry, no internet traffic. The point was to answer
a simple question *before* installing anything:

> Should a small, new, single-author GitHub project get the most sensitive permission macOS
> offers (Accessibility / global keyboard event tap) on my daily machine?

A project being on GitHub doesn't make it safe, and having no stars or issues doesn't make it
dangerous. It only means **nobody else has looked**. So I looked, fixed what I would not
accept, and documented it so anyone can check my work.

---

## Methodology

1. **Pinned the target.** Audited one immutable commit (`496855f`) and verified the SHA-256 of
   `Sources/main.swift` downloaded from GitHub against the cloned copy before any change.
2. **Read-only first.** Read every file as text through the GitHub API. Nothing was cloned,
   built or executed until the review was finished.
3. **Repository forensics.** Author account age and activity, commit history, releases
   (none, so no prebuilt binaries to trust), issues, contributors, dependencies (none beyond
   Apple frameworks).
4. **Full source review.** All ~850 lines of the single Swift file, plus `Info.plist`,
   `project.yml` and the install script, reviewed for: network endpoints, file and credential
   access, persistence, privilege use, process execution and telemetry.
5. **Separated evidence from claims.** Every finding is labelled as **verified in code** or
   **claimed by the README/docs**. Example: "zero configuration" and "tested on M9" are
   claims; the author's own status file says the newer features were *not yet tested on
   hardware*.
6. **Threat-modelled** the realistic attackers: a malicious/compromised future version, a
   hostile device on the same Wi-Fi (café, office, hotel), and other local processes/users.
7. **Patched minimally**, each change small, commented and independently reviewable.
8. **Verified** on real hardware: build, signature, network behaviour, permissions, key
   handling in both directions (see [Verification](#verification)).

---

## Findings (upstream, before hardening)

| Severity | Finding | Evidence |
|---|---|---|
| **High** | The keyboard event tap subscribed to **every `keyDown` system-wide** (needed only for optional ⌃⌥ hotkeys). With Accessibility granted, any future or tampered version would be a ready-made keylogger. | Verified: `CGEventMask((1 << 14) \| (1 << keyDown))` |
| **High (usability → availability)** | Volume keys were **swallowed unconditionally** while forwarding was on, even when audio was going to the laptop speakers or headphones. Away from the monitor, F10–F12 stopped working. | Verified: media-key branch returned `nil` with no output check |
| **Medium** | **TLS trust disabled.** The URLSession delegate accepted *any* server certificate from *any* host. A device on the same LAN could impersonate the monitor and capture the pairing token. | Verified: `completionHandler(.useCredential, URLCredential(trust: trust))` unconditionally |
| **Medium** | **Pairing token world-readable** (`0644` in the home folder). The token grants full remote control of the monitor. Acknowledged but unfixed by upstream. | Verified: `String.write(to:atomically:)`; upstream SESSION-LOG |
| **Medium** | **Network sweep on any network.** On every untrusted Wi-Fi the app probed all 254 hosts and reconnected (sending its token) to the last known IP. | Verified: `sweep()` / `connect()` had no network check |
| **Medium** | **Weak device identity.** Any HTTP body on `:8001` containing the text "M9" was adopted as the monitor. | Verified: `body.contains("M9")` only |
| **Low** | ATS globally disabled (`NSAllowsArbitraryLoads`). | Verified: `Info.plist` |
| **Low** | Auto-wake on by default: Wake-on-LAN broadcasts on every Mac wake. | Verified: `register(defaults: [autoWakeKey: true…])` |
| **Context** | 0 stars, 0 forks, 0 issues, single author, ~1 month of activity, history rewritten (force-push), AI-assisted, newer features self-reported as untested. Not a vulnerability, but it means no external review. | Verified: GitHub API; upstream STATUS.md |

**Confirmed clean (verified in code):** no internet hosts contacted, no analytics or telemetry,
no Keychain/clipboard/file access beyond its own token, no `sudo`, no launch daemons, login
item only when the user ticks the checkbox.

---

## Changes — before and after

| # | Area | Before | After | Where (`Sources/main.swift`) |
|---|---|---|---|---|
| 1 | Keyboard visibility | Tap on media keys **and all `keyDown`** | Tap on `NSSystemDefined` (media keys) **only**; the app can no longer see typing. ⌃⌥ hotkeys and Remote Mode removed; OK/Back/Home/Power kept as menu items | `createTap()`, `mediaKeyCallback` |
| 2 | Key ownership | F10–F12 always swallowed | Swallowed **only while the default audio output is the M9** (CoreAudio: DisplayPort/HDMI transport + model name). Otherwise they pass through to macOS. Manual toggle still available | `defaultOutputIsM9()` |
| 3 | TLS | Any certificate, any host | **Trust-on-first-use pinning** of the monitor's self-signed cert (SHA-256 of leaf DER); only the adopted IP on `:8002` is considered; mismatch is refused and surfaced in the menu | `urlSession(_:didReceive:completionHandler:)` |
| 4 | Token storage | `0644` | Created `0600`, existing files tightened, one-time migration to `~/.mymacmonitor_token` | `init()`, `handle(_:)` |
| 5 | Network scope | Sweeps/connects on any network | Remembers the /24 where the monitor was found; elsewhere **no sweep, no connect, no Wake-on-LAN** until the user deliberately clicks *Rescan (this network)* | `onHomeNetwork()` |
| 6 | Device identity | Body contains "M9" | Also requires a Samsung-style JSON `device` object | `probe(_:)` |
| 7 | Auto-wake | On by default | **Opt-in** | `applicationDidFinishLaunching` |
| 8 | ATS | `NSAllowsArbitraryLoads` | `NSAllowsLocalNetworking` (LAN only) | `Info.plist`, `project.yml` |
| 9 | Recovery | Manual `rm` of token | **Reset pairing…** menu item with a warning that an unexpected certificate change may mean impersonation | `resetPairing()` |
| 10 | Build | Homebrew + xcodegen, script installs into `/Applications` and launches | `build.sh`: plain `swiftc`, no third-party tools, builds outside iCloud-synced folders, **never installs**; `install.sh` is a separate, explicit step | `build.sh`, `install.sh` |

Diff against the audited upstream commit:

```sh
git diff 496855f -- Sources/main.swift Info.plist project.yml
```

---

## Verification

Tested on a MacBook Air (M3), macOS 27.2, with a Samsung Smart Monitor M9 (M90SF) over USB-C.

| Check | Method | Result |
|---|---|---|
| Builds cleanly | `./build.sh` (Swift 6.4) | ✅ no errors, no warnings |
| Signature | `codesign --verify --strict`, `codesign -dv` | ✅ valid, `flags=adhoc,runtime` |
| Only LAN traffic | `nettop -p <pid>` | ✅ exactly one connection: Mac → monitor `:8002`; no internet hosts |
| Certificate pinning | `openssl s_client` fingerprint vs. stored pin | ✅ identical |
| Token permissions | `stat -f %Lp ~/.mymacmonitor_token` | ✅ `600` |
| Output detection | Standalone harness calling `defaultOutputIsM9()` | ✅ `true` with the monitor as output |
| Keys → monitor | F10/F11/F12 with the monitor as output | ✅ monitor volume/mute changes |
| Keys → Mac | F10/F11/F12 with built-in speakers as output | ✅ normal macOS volume HUD |
| Resource use | `top`, `ps` while idle | ✅ ~0.0 % CPU, ~33 MB RAM, ~0 energy impact |

**Not yet exercised:** behaviour on a foreign network, *Reset pairing…*, auto-wake, Launch at
Login over reboots.

---

## Residual risks (accepted, documented)

- **Accessibility is still required.** It's now scoped to media keys in code, but the
  *permission itself* is broad. Review it in *System Settings → Privacy & Security →
  Accessibility*, and re-audit before trusting any new version.
- **Trust on first use.** If an attacker is already impersonating the monitor during the very
  first pairing, that certificate gets pinned. Pair on a network you control.
- **The monitor must be on Wi-Fi**, which puts its Tizen OS on the network (and in contact
  with Samsung). Decline optional data-sharing agreements on the monitor.
- **No sandbox** (a sandboxed app can't create a global event tap). Hardened runtime is on.
- **Ad-hoc signing.** Rebuilding changes the code hash, so macOS asks for Accessibility again.
  That's expected, and actually a useful tripwire.
- **Unmaintained upstream.** This fork is pinned. Upstream changes are not pulled automatically.

---

## Practices I'd recommend for any small open-source utility

1. Pin an exact commit and checksum it; never install from a moving branch.
2. Read before you build; build before you run; run before you grant permissions.
3. Prefer building from source with first-party tools over prebuilt binaries from unknown
   publishers.
4. Grep for network endpoints, `Process`, `FileManager` writes, Keychain, clipboard and
   persistence APIs, then read every hit.
5. Ask "what could the *next* version do with this permission?", not only "what does this
   version do?".
6. Observe the running app (`nettop`, `lsof`, `codesign -dv`) instead of trusting claims.
7. Keep fixes small and documented so the diff itself is reviewable.

---

## Credits & transparency

Original app and protocol research by [Omer Faruk Oztemiz](https://github.com/omarozt) (MIT).
The audit, patches and this report were prepared with AI assistance (Claude Code), then
reviewed and tested on real hardware by me.
