# Samsung M9 / Tizen Remote — Protocol Notes

Developer/tinkerer notes on how My MacMonitor (fork of M9Volume) talks to a Samsung Smart
Monitor M9. The protocol research is by the upstream author; the security-related parts were
updated for this fork. See [../README.md](../README.md) and
[../SECURITY-AUDIT.md](../SECURITY-AUDIT.md).

The M9 runs **Tizen** and does **not** support DDC/CI, so brightness/volume tools like
MonitorControl and BetterDisplay can't see it. Control happens over the **Samsung WebSocket
remote** — the same API family Samsung TVs use.

---

## WebSocket remote endpoint (control channel)

This is the channel that sends key presses.

```
wss://<IP>:8002/api/v2/channels/samsung.remote.control?name=<base64-name>&token=<token>
```

- `name` is a client label, **base64-encoded** (this app uses `MyMacMonitor`; it's what the
  monitor lists under connected devices).
- **Self-signed TLS.** The monitor presents a self-signed certificate, so CA validation is
  impossible. Upstream accepted *any* certificate from *any* host; this fork **pins the
  certificate on first use** (SHA-256 of the leaf DER) and only answers challenges for the
  adopted monitor IP on `:8002`. A mismatch is refused and shown in the menu.
- **Token flow (first-run pairing):**
  1. Connect with **no `token`** parameter.
  2. The monitor shows an on-screen **Allow / Deny** dialog.
  3. On Allow, the granted token arrives in an `ms.channel.connect` event
     (`data.token` in the JSON).
  4. **Persist it** and append `&token=<token>` on every later connect.
     This app stores it owner-only (`0600`) at `~/.mymacmonitor_token`.
- An `unauthorized` message means the token was rejected — drop the connection and re-pair.

### Sending a key

Send this JSON string over the socket:

```json
{
  "method": "ms.remote.control",
  "params": {
    "Cmd": "Click",
    "DataOfCmd": "KEY_VOLUP",
    "Option": "false",
    "TypeOfRemote": "SendRemoteKey"
  }
}
```

Swap `DataOfCmd` for any supported key (below).

---

## Device-info endpoint (`:8001`)

```
GET http://<IP>:8001/api/v2/
```

Returns a JSON blob describing the device. The two fields this app uses live under `device`:

- **`device.PowerState`** — `"on"` or `"standby"`. Gates the guarded power key on the
  auto-wake path.
- **`device.wifiMac`** — the Wi-Fi MAC, used as the Wake-on-LAN target.

**Important:** this endpoint only answers in **network standby** (NIC alive). In **deep
standby** the NIC is off and both this endpoint and the WebSocket are unreachable — see
Wake-on-LAN below.

---

## Key semantics

Supported keys: `KEY_VOLUP`, `KEY_VOLDOWN`, `KEY_MUTE`, `KEY_LEFT`, `KEY_RIGHT`, `KEY_UP`,
`KEY_DOWN`, `KEY_ENTER` (OK), `KEY_RETURN` (Back), `KEY_HOME`, `KEY_POWER`.

- **Volume is relative only.** There is no absolute "set volume to N" over this channel — only
  `KEY_VOLUP` / `KEY_VOLDOWN` nudges. (That's why the app has no 0–100 slider.)
- **`KEY_MUTE` is a toggle**, and the mute state **can't be read back** locally.
- **"Force unmute" trick.** Because mute is toggle-only and unreadable, you can't
  unconditionally un-mute. The workaround: send `KEY_VOLUP` then `KEY_VOLDOWN` — net-zero on
  volume, but any volume key clears mute. (App inserts ~0.18 s between the two.)
- **`KEY_POWER` is a toggle whose state can't be read back** (on recent Tizen
  `KEY_POWEROFF == KEY_POWER`). This makes it dangerous:
  - **Never blind-send it** — you can't tell whether you're turning the monitor on or off.
  - **Never queue it.** A queued power key would flush on the next reconnect and switch a
    just-woken monitor back off. In this app `KEY_POWER` bypasses the pending-key queue
    entirely: it's sent only over a **live socket**, on the auto path **only when a probe
    explicitly returned `"standby"`**, and dropped on failure rather than enqueued.
  - Consequence: powering the monitor **off** requires a live WebSocket. During a transient
    disconnect the app probes, sees `"on"`, and deliberately does nothing rather than risk a
    stale toggle.

---

## Wake-on-LAN

In **deep standby** the NIC is off, so the WebSocket and `:8001` are both dead and a WoL
magic packet is the only wake lever.

- **Magic packet:** 6 bytes of `0xFF` followed by the 6-byte MAC repeated **16×**
  (6 + 16×6 = 102 bytes).
- **Transport:** UDP, destination port **9**, with `SO_BROADCAST` set.
- **Send to both** `255.255.255.255` **and** the subnet-directed broadcast `<base>.255` —
  some access points drop the global broadcast, so the directed one is the fallback (and vice
  versa).
- **Requires the monitor setting** `Settings > General > Network > Expert Settings >
  "Power On with Mobile"` (WoWLAN) = **ON**. Without it the monitor reaches deep standby with
  the NIC dead and no software can wake it.

Auto-wake sequence: always send WoL (harmless if already on) → probe `:8001`. Only
`PowerState == "standby"` from a reachable probe, **and** a live WebSocket, sends the guarded
`KEY_POWER`. `"on"` / missing / unreachable never toggle. (Note: the millisecond HTTP probe
usually wins the race against the TLS+upgrade WebSocket handshake, so the code retries until
the socket is up before it can deliver the power key.)

---

## Discovery

No hardcoded IP — the monitor is found by sweep, **only on the home network** (the /24 where
it was first found; elsewhere the app neither sweeps nor connects):

1. Try the saved IP first (`m9_last_ip`).
2. Otherwise sweep the local **/24**: derive the base from the Mac's **en0/en1** IPv4 address
   (via `getifaddrs`), then probe `http://<base>.1..254:8001/api/v2/` in parallel.
3. **Match "M9" in the raw response body** (the hit is in **`device.name`**, *not*
   `modelName`, which is a sales code without "M9"), **and** require the body to be a JSON
   object with a `device` dictionary.

Reconnect is proactive with exponential backoff (1→10 s), reconnects on system/display wake,
and re-sweeps after repeated failures (the IP may have changed via DHCP).

---

## Dead ends (documented so you don't repeat them)

- **UPnP RenderingControl is a non-functional stub.** The M9 advertises a MediaRenderer at
  `http://<IP>:9197/dmr` with a standard-looking RenderingControl SCPD
  (`GetVolume`/`SetVolume`, `Channel=Master`, `Volume` 0–100), but **every call returns
  HTTP 400 / UPnPError 402 "Invalid Args"** even with the documented arguments. Do **not** use
  UPnP for volume — this is why there's no absolute 0–100 slider.
- **SmartThings would give absolute volume** (the `audioVolume` capability), but Personal
  Access Tokens now expire in ~24 h, which would force a full OAuth flow. Not worth it for
  this app; not used.

---

## Prior art

This is the same WebSocket remote API family used by Samsung TVs. Reference implementations
that informed these notes:

- [`samsungtvws`](https://github.com/xchwarze/samsung-tv-ws-api) (Python)
- Home Assistant's [`samsungtv`](https://www.home-assistant.io/integrations/samsungtv/)
  integration
- [`homebridge-tizen`](https://github.com/tavicu/homebridge-samsung-tizen)
