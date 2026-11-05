# MyMacMonitor — Setup Guide

End-user setup for MyMacMonitor, the macOS menu-bar app that lets the Mac keyboard's volume
keys control a Samsung Smart Monitor M9. See [../README.md](../README.md) for the overview and
[../SECURITY-AUDIT.md](../SECURITY-AUDIT.md) for the security model.

---

## 1. Prerequisites

- **macOS 13 (Ventura) or later**, Apple Silicon. Launch at Login uses `SMAppService` (13+).
- **The M9 on the same /24 subnet as the Mac.** The app finds the monitor by sweeping the
  local subnet; a different VLAN or a "guest" Wi-Fi that isolates clients will hide it.
  The USB-C cable only carries video/audio; control goes over Wi-Fi.
- **Xcode or the Command Line Tools** (`xcode-select --install`). Nothing else.

---

## 2. Build and install

```sh
./build.sh      # → ~/Library/Caches/MyMacMonitor-build/MyMacMonitor.app (installs nothing)
./install.sh    # → /Applications/MyMacMonitor.app, then opens it
```

- `build.sh` compiles with `swiftc`, embeds the icon and **ad-hoc signs** the app with the
  hardened runtime. It writes outside `~/Documents` on purpose: iCloud Drive's Desktop &
  Documents sync stamps Finder/file-provider attributes onto bundles, which breaks the code
  signature.
- `install.sh` is a separate, explicit step. Running from `/Applications` (a stable path) is
  what makes Launch at Login reliable.
- App Sandbox is intentionally **off** (a sandboxed app cannot create the global event tap the
  volume keys need). Hardened runtime is **on**.

> **Rebuilds and Accessibility.** macOS ties the Accessibility grant to the app's code
> signature. Every rebuild produces a new ad-hoc signature, so macOS asks again, and the old
> entry in *Privacy & Security → Accessibility* should be removed. That's expected.

---

## 3. First launch (do it on your home network)

1. **Accessibility permission (macOS).** The app installs an event tap for the **media keys
   only**. Grant it in **System Settings → Privacy & Security → Accessibility**. The app
   relaunches itself within ~1–2 s (macOS only applies a fresh grant to a new process).
2. **Local Network (macOS)**, if asked: allow it, since discovery needs the LAN.
3. **The monitor's "Allow" dialog (Tizen).** The first connection shows an Allow/Deny prompt on
   the monitor. Choose **Allow**. The token is stored owner-only at `~/.mymacmonitor_token`.
4. At that moment the app **pins the monitor's TLS certificate** and remembers this subnet as
   its home network.

---

## 4. Verify it works

- The menu-bar icon (display + speaker) shows **"M9 — connected (…)"**.
- With the monitor selected as sound output, **F11/F12/F10** change the monitor's volume/mute.
- Switch the output to the Mac's speakers: the same keys show the normal macOS volume HUD.

---

## 5. Settings

Menu → **Settings…**

- **Monitor**: connection status, the monitor's Wi-Fi MAC (Wake-on-LAN target), **Rescan**.
- **Forward volume keys to M9**: master switch. Even when on, keys are only taken while the
  monitor is the sound output.
- **Auto-wake monitor when the Mac wakes**: **off** by default. Requires the monitor setting
  *Settings → General → Network → Expert Settings → "Power On with Mobile"* (this keeps the
  monitor's network chip alive in standby, at some power and exposure cost).
- **Launch at Login**: registers the app as a login item (needs the `/Applications` copy).

Menu items **OK / Back / Home / Monitor Power** drive the monitor's own UI with a click.

---

## 6. Troubleshooting

### "M9 — not on the monitor's network"
You're on a different Wi-Fi than the one where the monitor was paired. The app deliberately
does nothing here (no scanning, no token sent). If you **moved** home networks, connect to the
new one and click **Rescan for monitor (this network)**.

### "M9 — certificate changed!"
The monitor presented a different TLS certificate than the pinned one. If you **just reset or
updated** the monitor, use **Reset pairing…** and accept the monitor's Allow prompt again. If
you didn't, treat it as a possible impersonation attempt on your network and don't reset.

### "M9 — searching…" never resolves
- Mac and monitor must share the same /24 (`192.168.x.*`). Check the monitor's IP in
  *Settings → General → Network → Network Status*.
- The subnet is read from the Mac's `en0`/`en1` (Wi-Fi). Unusual interfaces may not work.
- DHCP may have moved the monitor: **Rescan**. A DHCP reservation avoids churn.

### Volume keys don't reach the monitor
- Is the monitor the **sound output**? (*System Settings → Sound → Output*.) By design, keys
  only go to it then.
- Accessibility granted to *this* build? Remove stale entries and re-grant.
- Keys are inert inside secure-input fields (password prompts). That's macOS by design.

### Powering the monitor off while disconnected does nothing
By design: `KEY_POWER` is a toggle whose state can't be read, so it's never blind-sent or
queued. See [PROTOCOL.md](PROTOCOL.md).

---

## 7. Persisted state

`UserDefaults` domain `io.github.gerevolver.mymacmonitor`:

| Key | Meaning |
|---|---|
| `m9_last_ip` | Last known monitor IP |
| `m9_home_subnet` | /24 where the monitor was found (network scope) |
| `m9_cert_sha256` | Pinned monitor certificate fingerprint |
| `m9_wifi_mac` | Monitor Wi-Fi MAC (Wake-on-LAN target) |
| `m9_autowake` | Auto-wake toggle (default off) |
| `m9_forward_keys` | Forward-keys toggle (default on) |

```sh
defaults read io.github.gerevolver.mymacmonitor
stat -f %Lp ~/.mymacmonitor_token     # should print 600
```
