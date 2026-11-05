// main.swift — My MacMonitor (menu-bar agent)
//
// Forwards the Mac keyboard's volume up / down / mute keys to a Samsung Smart
// Monitor M9 over its Wi-Fi WebSocket remote. Menu-bar only, no Dock icon.
//
// This build adds:
//   * IP auto-discovery (remembers last IP; sweeps the /24 to find the M9 by model)
//   * Faster reconnect (proactive, with backoff; reconnects on system wake; and
//     re-discovers the IP if it keeps failing — e.g. DHCP gave it a new address)
//   * "Launch at Login" toggle (SMAppService) — works once it's a real .app
//   * Auto-wake the monitor on Mac/displays wake (Wake-on-LAN + guarded KEY_POWER)
//
// Hardened fork (branch `hardened`, based on omarozt/M9Volume@496855f) — see SECURITY-AUDIT.md:
//   * The event tap listens ONLY to system media keys (no keyDown) — the ⌃⌥ hotkeys and
//     Remote Mode were removed; OK/Back/Home/Power remain as menu items.
//   * Volume keys are swallowed only while the default audio output is the M9; anywhere
//     else (built-in speakers, AirPods…) they pass through to macOS untouched.
//   * Trust-on-first-use pin of the monitor's TLS certificate; challenges from any other
//     host/port are rejected.
//   * Pairing token written 0600; discovery/connection limited to the network the M9 was
//     first found on; auto-wake off by default.
//
// Build with ./build.sh (no install); install explicitly with ./install.sh.

import Cocoa
import CoreAudio
import CryptoKit
import ServiceManagement

// MARK: - WebSocket remote + discovery ---------------------------------------

final class M9Remote: NSObject, URLSessionWebSocketDelegate {
    static let clientName = "MyMacMonitor"   // name shown in the monitor's device list
    static let modelKeyword = "M9"            // matched against the raw :8001 body — the hit
                                              // is in device.name; modelName is a sales code
    private let ipKey = "m9_last_ip"
    private let wifiMacKey = "m9_wifi_mac"    // persisted for Wake-on-LAN across launches
    private let certPinKey = "m9_cert_sha256" // TOFU pin of the monitor's TLS cert (DER SHA-256)
    private let homeSubnetKey = "m9_home_subnet" // /24 base the M9 was found on
    private let tokenURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mymacmonitor_token")
    private let legacyTokenURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".m9volume_token")   // pre-rebrand location

    /// Parsed from the :8001/api/v2/ probe. `wifiMac` feeds Wake-on-LAN; `powerState`
    /// ("on"/"standby") gates the guarded KEY_POWER on the auto-wake path.
    struct DeviceInfo {
        let wifiMac: String?
        let powerState: String?
    }

    private(set) var ip: String?
    private(set) var connected = false
    private(set) var certMismatch = false       // pinned cert no longer matches; set on main
    var onUpdate: (() -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var connecting = false
    private var reconnectScheduled = false
    private var attempts = 0
    private var pending: [String] = []
    private var sweeping = false
    private var wifiMac: String?
    private var waking = false                 // wake sequence in flight; toggled on main

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        wifiMac = UserDefaults.standard.string(forKey: wifiMacKey)
        // One-time move of a pre-rebrand token, then tighten it (older builds wrote 0644).
        let fm = FileManager.default
        if !fm.fileExists(atPath: tokenURL.path), fm.fileExists(atPath: legacyTokenURL.path) {
            try? fm.moveItem(at: legacyTokenURL, to: tokenURL)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
    }

    // Discovery ---------------------------------------------------------------

    /// True until the M9 has been found once; afterwards only on that same /24. Keeps the
    /// app from probing/sweeping (and sending its token to) hosts on foreign networks.
    func onHomeNetwork() -> Bool {
        guard let home = UserDefaults.standard.string(forKey: homeSubnetKey) else { return true }
        return Self.localSubnetBase() == home
    }

    func start() {
        guard onHomeNetwork() else { DispatchQueue.main.async { self.onUpdate?() }; return }
        if let saved = UserDefaults.standard.string(forKey: ipKey) {
            probe(saved) { [weak self] info in
                guard let self = self else { return }
                if let info = info { self.adopt(saved, info); self.connect() } else { self.sweep() }
            }
        } else {
            sweep()
        }
    }

    private func setIP(_ value: String) {
        ip = value
        UserDefaults.standard.set(value, forKey: ipKey)
        DispatchQueue.main.async { self.onUpdate?() }
    }

    /// Accept a confirmed M9: set the IP and persist its wifiMac for later Wake-on-LAN.
    /// The wake sequence reads `wifiMac` on main, so the write hops there too (adopt is
    /// called from URLSession completion queues).
    private func adopt(_ ip: String, _ info: DeviceInfo) {
        if let dot = ip.range(of: ".", options: .backwards) {
            UserDefaults.standard.set(String(ip[..<dot.lowerBound]), forKey: homeSubnetKey)
        }
        if let mac = info.wifiMac {
            DispatchQueue.main.async {
                self.wifiMac = mac
                UserDefaults.standard.set(mac, forKey: self.wifiMacKey)
            }
        }
        setIP(ip)
    }

    /// GET http://IP:8001/api/v2/ — the raw-body `contains("M9")` test is the proven
    /// identity check (the hit is in device.name, not the sales-code modelName). Also
    /// parses wifiMac + PowerState. `nil` = not-an-M9 or unreachable.
    private func probe(_ ip: String, timeout: TimeInterval = 2,
                       completion: @escaping (DeviceInfo?) -> Void) {
        guard let url = URL(string: "http://\(ip):8001/api/v2/") else { completion(nil); return }
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        session.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let body = String(data: data, encoding: .utf8),
                  body.contains(Self.modelKeyword),
                  // Must also be a Samsung-style device-info JSON, not just any body with "M9".
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let device = obj["device"] as? [String: Any] else { completion(nil); return }
            completion(DeviceInfo(wifiMac: device["wifiMac"] as? String,
                                  powerState: device["PowerState"] as? String))
        }.resume()
    }

    func sweep() {
        guard !sweeping, onHomeNetwork(), let base = Self.localSubnetBase() else { return }
        sweeping = true
        DispatchQueue.main.async { self.onUpdate?() }      // shows "searching…"
        let group = DispatchGroup()
        let lock = NSLock()
        var found: (ip: String, info: DeviceInfo)?
        for i in 1...254 {
            let candidate = "\(base).\(i)"
            group.enter()
            probe(candidate) { info in
                if let info = info { lock.lock(); if found == nil { found = (candidate, info) }; lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.sweeping = false
            if let found = found { self.adopt(found.ip, found.info); self.attempts = 0; self.connect() }
            else { self.onUpdate?() }
        }
    }

    /// First non-loopback IPv4 on en0/en1, reduced to its /24 base (e.g. "192.168.1").
    static func localSubnetBase() -> String? {
        var result: String?
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return nil }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = start
        while let cur = p {
            let flags = Int32(cur.pointee.ifa_flags)
            if let addr = cur.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 {
                let name = String(cString: cur.pointee.ifa_name)
                if name == "en0" || name == "en1" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                   &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ipStr = String(cString: host)
                        if let dot = ipStr.range(of: ".", options: .backwards) {
                            result = String(ipStr[..<dot.lowerBound]); break
                        }
                    }
                }
            }
            p = cur.pointee.ifa_next
        }
        return result
    }

    // Connection --------------------------------------------------------------

    func connect() {
        guard !connected, !connecting, let ip = ip, onHomeNetwork() else { return }
        connecting = true
        let name64 = Data(Self.clientName.utf8).base64EncodedString()
        var urlStr = "wss://\(ip):8002/api/v2/channels/samsung.remote.control?name=\(name64)"
        if let t = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            urlStr += "&token=\(t)"
        }
        guard let url = URL(string: urlStr) else { connecting = false; return }
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                self.markDisconnected()
            case .success(let msg):
                if case .string(let text) = msg { self.handle(text) }
                self.receive()
            }
        }
    }

    private func handle(_ text: String) {
        if text.contains("ms.channel.connect") {
            if let data = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = obj["data"] as? [String: Any],
               let token = d["token"] as? String {
                // Owner-only from the first byte (createFile applies the mode on creation),
                // then re-assert it in case the file already existed with looser bits.
                FileManager.default.createFile(atPath: tokenURL.path, contents: Data(token.utf8),
                                               attributes: [.posixPermissions: 0o600])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
            }
            connected = true; connecting = false; attempts = 0
            DispatchQueue.main.async { self.onUpdate?() }
            let queued = pending; pending.removeAll()
            for k in queued { rawSend(k) }
        } else if text.contains("unauthorized") {
            markDisconnected()
        }
    }

    private func markDisconnected() {
        connected = false; connecting = false; task = nil
        DispatchQueue.main.async { self.onUpdate?() }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !connected, !connecting, !reconnectScheduled, ip != nil else { return }
        reconnectScheduled = true
        let delay = min(pow(2.0, Double(attempts)), 10.0)   // 1,2,4,8,10…
        attempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.reconnectScheduled = false
            if self.attempts >= 5 { self.attempts = 0; self.sweep() }  // IP may have changed
            else { self.connect() }
        }
    }

    /// Called on system wake — try to get back instantly.
    func reconnectNow() {
        attempts = 0; reconnectScheduled = false
        if !connected { connect() }
    }

    /// Manual rescan from the menu: also re-homes discovery onto the current network, so a
    /// deliberate click is the only way the app ever sweeps a network other than the first.
    func rescan() {
        UserDefaults.standard.removeObject(forKey: ipKey)
        UserDefaults.standard.removeObject(forKey: homeSubnetKey)
        connected = false; connecting = false; task = nil; attempts = 0
        sweep()
    }

    /// Forget the pairing token and the pinned certificate — needed if the monitor is reset
    /// or its certificate changes (e.g. after a firmware update). The next connect shows the
    /// monitor's Allow dialog again and pins the new certificate.
    func resetPairing() {
        try? FileManager.default.removeItem(at: tokenURL)
        UserDefaults.standard.removeObject(forKey: certPinKey)
        certMismatch = false
        // A live socket's receive() fails on cancel → markDisconnected → reconnect (no token).
        if let t = task { t.cancel(with: .goingAway, reason: nil) } else { attempts = 0; connect() }
    }

    // Sending -----------------------------------------------------------------

    private func payload(_ key: String) -> String {
        let p: [String: Any] = ["method": "ms.remote.control",
                                "params": ["Cmd": "Click", "DataOfCmd": key,
                                           "Option": "false", "TypeOfRemote": "SendRemoteKey"]]
        let data = (try? JSONSerialization.data(withJSONObject: p)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func rawSend(_ key: String) {
        guard let task = task else { queue(key); connect(); return }
        task.send(.string(payload(key))) { [weak self] err in
            guard err != nil, let self = self else { return }
            self.queue(key)
            DispatchQueue.main.async { self.markDisconnected() }
        }
    }

    private func queue(_ key: String) {
        if pending.count < 8 { pending.append(key) }
    }

    func send(_ key: String) {
        if connected { rawSend(key) }
        else { queue(key); if ip != nil { connect() } else { start() } }
    }

    func forceUnmute() {
        send("KEY_VOLUP")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.send("KEY_VOLDOWN")
        }
    }

    // Wake --------------------------------------------------------------------

    /// KEY_POWER is a toggle and must NEVER be queued — a queued power key would flush on
    /// the next connect and turn the just-woken monitor back OFF. Send only over a live
    /// socket; on failure drop it (mark disconnected) rather than enqueue.
    func sendPowerIfConnected() {
        guard connected, let task = task else { return }
        task.send(.string(payload("KEY_POWER"))) { [weak self] err in
            guard err != nil, let self = self else { return }
            DispatchQueue.main.async { self.markDisconnected() }
        }
    }

    /// Wake-on-LAN magic packet (6×0xFF + 16×MAC) to UDP :9. In deep standby the NIC is
    /// off (HTTP/WS both unreachable), so WoL is the only wake lever; requires the monitor
    /// setting "Power On with Mobile". Sent to the global and subnet-directed broadcasts
    /// (some APs drop the global one). Harmless if the monitor is already on.
    private func sendWakeOnLAN() {
        guard let mac = wifiMac else { return }
        let macBytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard macBytes.count == 6 else { return }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: macBytes) }   // 6 + 16×6 = 102
        var targets = ["255.255.255.255"]
        if let base = Self.localSubnetBase() { targets.append("\(base).255") }
        DispatchQueue.global().async {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
            for target in targets {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(9).bigEndian
                addr.sin_addr.s_addr = inet_addr(target)
                _ = packet.withUnsafeBytes { buf in
                    withUnsafePointer(to: &addr) { aptr in
                        aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(fd, buf.baseAddress, buf.count, 0, sa,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }

    /// Auto-wake: WoL (always, harmless if on) → probe. Only PowerState=="standby" from a
    /// reachable probe sends the guarded KEY_POWER, and only once the WS is connected —
    /// standby-without-socket retries (the millisecond HTTP probe wins the race against
    /// the TLS+upgrade WS handshake, so waiting is the common case, not the exception).
    /// "on"/missing → done (never blind-toggle); unreachable → retry. Retries every 2 s
    /// until a ~20 s deadline, re-sending WoL each round. `waking` guards re-entry.
    func wakeMonitor() {
        DispatchQueue.main.async {
            // No WoL broadcasts or probes on networks other than the monitor's.
            guard !self.waking, self.onHomeNetwork() else { return }
            self.waking = true
            self.attemptWake(ip: self.ip, deadline: Date().addingTimeInterval(20))
        }
    }

    private func attemptWake(ip: String?, deadline: Date) {
        sendWakeOnLAN()
        // Discovery may land mid-sequence: retries pass nil so this coalescing re-reads
        // self.ip every round.
        guard let ip = ip ?? self.ip else {
            // No IP yet (monitor was dark at launch, sweep found nothing) — restart
            // discovery (the sweeping guard prevents storms) and retry once WoL has had
            // a chance to raise the NIC.
            start()
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.attemptWake(ip: nil, deadline: deadline)
                }
            } else {
                DispatchQueue.main.async { self.waking = false }
            }
            return
        }
        probe(ip, timeout: 2) { [weak self] info in
            guard let self = self else { return }
            if let info = info, info.powerState != "standby" {
                // "on" or PowerState missing — never blind-toggle.
                DispatchQueue.main.async { self.waking = false }
            } else if info != nil, self.connected {
                // standby + live socket → the guarded power press can actually land.
                self.sendPowerIfConnected()
                DispatchQueue.main.async { self.waking = false }
            } else if Date() < deadline {
                // standby without a socket — hasten the WS handshake (connect() dedupes
                // via its connecting/connected guards) so the power key can be delivered
                // next round; or unreachable. Either way retry after 2 s.
                if info != nil { self.connect() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.attemptWake(ip: nil, deadline: deadline)
                }
            } else {
                DispatchQueue.main.async { self.waking = false }
            }
        }
    }

    /// The monitor's cert is self-signed, so CA validation is impossible; instead pin it on
    /// first use (SHA-256 of the leaf DER) and refuse anything else afterwards. Only the
    /// adopted monitor IP on :8002 is ever considered — every other challenge is cancelled.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        guard space.host == ip, space.port == 8002,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }.joined()
        if let pinned = UserDefaults.standard.string(forKey: certPinKey) {
            guard pinned == fingerprint else {
                DispatchQueue.main.async { self.certMismatch = true; self.onUpdate?() }
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
        } else {
            UserDefaults.standard.set(fingerprint, forKey: certPinKey)   // trust on first use
        }
        DispatchQueue.main.async { self.certMismatch = false }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - Media-key event tap (C callback) -----------------------------------

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType,
                              event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        app.reenableTap()
        return Unmanaged.passUnretained(event)
    }

    // Volume keys are only taken over while macOS is actually sending audio to the M9;
    // with any other default output they fall through so the Mac's own volume works.
    if type.rawValue == 14, app.forwardingEnabled,              // 14 == NSSystemDefined
       let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
        let data1 = ns.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyState = (data1 & 0x0000FF00) >> 8                // 0x0A down
        // up / down / mute; the CoreAudio check runs only for these, never for play/brightness
        if (keyCode == 0 || keyCode == 1 || keyCode == 7), defaultOutputIsM9() {
            if keyState == 0x0A {
                switch keyCode {
                case 0: app.remote.send("KEY_VOLUP")
                case 1: app.remote.send("KEY_VOLDOWN")
                case 7: app.remote.send("KEY_MUTE")
                default: break
                }
            }
            return nil   // swallow
        }
    }
    return Unmanaged.passUnretained(event)
}

/// Default output device is the M9 when CoreAudio reports it on DisplayPort/HDMI and its
/// name carries the model (it shows up as e.g. "Smart M90SF"). Cheap property reads, so it
/// is evaluated per key press rather than cached.
func defaultOutputIsM9() -> Bool {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &device) == noErr,
          device != kAudioObjectUnknown else { return false }

    var transport = UInt32(0)
    size = UInt32(MemoryLayout<UInt32>.size)
    addr.mSelector = kAudioDevicePropertyTransportType
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr,
          transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI
    else { return false }

    var name: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    addr.mSelector = kAudioObjectPropertyName
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr,
          let cf = name?.takeRetainedValue() else { return false }
    return (cf as String).contains(M9Remote.modelKeyword)
}

// MARK: - App delegate / menu bar --------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
    let remote = M9Remote()
    var forwardingEnabled = true

    private let autoWakeKey = "m9_autowake"
    private let forwardKeysKey = "m9_forward_keys"    // persists forwardingEnabled across launches
    private var autoWakeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoWakeKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoWakeKey) }
    }

    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permTimer: Timer?

    // Settings window + its controls, built lazily on first open. Strong refs are required:
    // the window is isReleasedWhenClosed = false and refreshSettingsUI reads/writes the
    // controls to keep them in sync with the menu.
    private var settingsWindow: NSWindow?
    private var settingsStatusLabel: NSTextField?
    private var settingsMacLabel: NSTextField?
    private var forwardCheckbox: NSButton?
    private var autoWakeCheckbox: NSButton?
    private var loginCheckbox: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Auto-wake is opt-in: it broadcasts Wake-on-LAN on every Mac wake.
        UserDefaults.standard.register(defaults: [autoWakeKey: false, forwardKeysKey: true])
        forwardingEnabled = UserDefaults.standard.bool(forKey: forwardKeysKey)  // before createTap()
        setupMenu()
        remote.onUpdate = { [weak self] in self?.refreshMenu() }
        remote.start()

        promptAccessibilityIfNeeded()
        createTap()
        if eventTap == nil {
            permTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                guard AXIsProcessTrusted() else { return }
                t.invalidate()
                // TCC only applies a freshly-granted Accessibility permission to a
                // newly-launched process; CGEvent.tapCreate will silently fail in
                // this one even though AXIsProcessTrusted now returns true.
                self.relaunchSelf()
            }
        }

        // Reconnect promptly on Mac wake and on displays-wake-after-idle; also auto-wake
        // the monitor (WoL + guarded power) when enabled. No power assertions anywhere —
        // the monitor must still sleep normally.
        let onWake: (Notification) -> Void = { [weak self] _ in
            guard let self = self else { return }
            self.remote.reconnectNow()
            if self.autoWakeEnabled { self.remote.wakeMonitor() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: onWake)
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: onWake)

        refreshMenu()
    }

    // Menu --------------------------------------------------------------------

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        statusItem.menu = NSMenu()
    }

    /// A display+speaker glyph with an SF Symbol fallback chain (glyphs vary by release).
    /// Images stay template so the menu bar tints them per appearance.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        if let img = symbol("tv.and.hifispeaker.fill", "display", "speaker.wave.2.fill",
                            accessibility: "My MacMonitor") {
            button.image = img
        } else {
            button.title = "M9"
        }
    }

    /// First available SF Symbol in `names` as a template image, or nil if none exist.
    private func symbol(_ names: String..., accessibility: String) -> NSImage? {
        for name in names {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: accessibility) {
                img.isTemplate = true
                return img
            }
        }
        return nil
    }

    /// Menu-header / Settings status string. Shared so both surfaces read identically.
    private func statusString() -> String {
        if remote.certMismatch { return "M9 — certificate changed! (Reset pairing if expected)" }
        if !remote.onHomeNetwork() { return "M9 — not on the monitor's network" }
        if let ip = remote.ip { return remote.connected ? "M9 — connected (\(ip))" : "M9 — \(ip) (offline)" }
        return "M9 — searching…"
    }

    private func refreshMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let header = NSMenuItem(title: statusString(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let trusted = AXIsProcessTrusted()
        let fwd = NSMenuItem(title: "Forward volume keys to M9", action: #selector(toggleForwarding), keyEquivalent: "")
        fwd.state = (forwardingEnabled && trusted) ? .on : .off
        fwd.target = self
        menu.addItem(fwd)
        if !trusted {
            let warn = NSMenuItem(title: "Grant Accessibility to capture keys…", action: #selector(openAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }

        menu.addItem(.separator())
        let actions: [(String, Selector)] = [
            ("Volume Up", #selector(volUp)), ("Volume Down", #selector(volDown)),
            ("Mute (toggle)", #selector(mute)), ("Unmute", #selector(unmute)),
        ]
        for (t, sel) in actions {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: ""); it.target = self
            menu.addItem(it)
        }

        // Remote nav, click-only (the keyboard hotkeys were removed with the keyDown tap).
        menu.addItem(.separator())
        let nav: [(String, Selector)] = [
            ("OK", #selector(okPress)), ("Back", #selector(backPress)),
            ("Home", #selector(homePress)), ("Monitor Power", #selector(powerToggle)),
        ]
        for (t, sel) in nav {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: ""); it.target = self
            menu.addItem(it)
        }

        // Launch-at-Login and Auto-wake now live only in Settings.
        menu.addItem(.separator())
        let rescan = NSMenuItem(title: "Rescan for monitor (this network)", action: #selector(rescan), keyEquivalent: "")
        rescan.target = self
        menu.addItem(rescan)
        let repair = NSMenuItem(title: "Reset pairing…", action: #selector(resetPairing), keyEquivalent: "")
        repair.target = self
        menu.addItem(repair)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]     // display-only, like the nav items
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: "About My MacMonitor", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)

        if settingsWindow?.isVisible == true { refreshSettingsUI() }
    }

    @objc private func toggleForwarding() { setForwarding(!forwardingEnabled) }
    /// Flip only the flag (persisted) — the tap stays enabled so the always-on hotkeys keep
    /// working. `forwardingEnabled` gates only the media-key branch inside the callback.
    private func setForwarding(_ on: Bool) {
        forwardingEnabled = on
        UserDefaults.standard.set(on, forKey: forwardKeysKey)
        if eventTap == nil { createTap() }
        refreshMenu()
    }
    /// Register/unregister the login item; the failure alert explains the /Applications
    /// requirement. Shared by the Settings checkbox. Callers refresh their own UI.
    private func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            let a = NSAlert(); a.messageText = "Launch at Login failed"
            a.informativeText = "\(error.localizedDescription)\n\nThis works when run as My MacMonitor.app in /Applications."
            a.runModal()
        }
    }
    @objc private func volUp()   { remote.send("KEY_VOLUP") }
    @objc private func volDown() { remote.send("KEY_VOLDOWN") }
    @objc private func mute()    { remote.send("KEY_MUTE") }
    @objc private func unmute()  { remote.forceUnmute() }
    @objc private func okPress()   { remote.send("KEY_ENTER") }
    @objc private func backPress() { remote.send("KEY_RETURN") }
    @objc private func homePress() { remote.send("KEY_HOME") }
    @objc private func resetPairing() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Reset pairing with the M9?"
        a.informativeText = "Forgets the saved token and the pinned certificate. The monitor will " +
            "show its Allow dialog again on the next connection. Do this only if you reset or " +
            "updated the monitor — an unexpected certificate change can mean someone is " +
            "impersonating it on your network."
        a.addButton(withTitle: "Reset"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { remote.resetPairing() }
    }

    // Settings checkboxes apply immediately (no Save button).
    @objc private func forwardCheckboxChanged(_ sender: NSButton) { setForwarding(sender.state == .on) }
    @objc private func autoWakeCheckboxChanged(_ sender: NSButton) {
        autoWakeEnabled = (sender.state == .on); refreshMenu()
    }
    @objc private func loginCheckboxChanged(_ sender: NSButton) {
        setLaunchAtLogin(sender.state == .on)
        refreshSettingsUI()   // reflect the real status (register/unregister may have failed)
    }

    // Settings window ---------------------------------------------------------

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = buildSettingsWindow() }
        refreshSettingsUI()
        NSApp.activate(ignoringOtherApps: true)     // .accessory app must activate to show a window
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Programmatic AppKit (no SwiftUI/xib). isReleasedWhenClosed = false or closing the
    /// window double-releases it. Height derives from the stack; width fixed so labels wrap.
    private func buildSettingsWindow() -> NSWindow {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let statusLabel = NSTextField(labelWithString: "")
        let macLabel = NSTextField(labelWithString: "—")
        macLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        macLabel.textColor = .secondaryLabelColor
        let rescanBtn = NSButton(title: "Rescan", target: self, action: #selector(rescan))
        rescanBtn.bezelStyle = .rounded
        settingsStatusLabel = statusLabel
        settingsMacLabel = macLabel

        let fwd = NSButton(checkboxWithTitle: "Forward volume keys to M9",
                           target: self, action: #selector(forwardCheckboxChanged(_:)))
        let aw = NSButton(checkboxWithTitle: "Auto-wake monitor when the Mac wakes",
                          target: self, action: #selector(autoWakeCheckboxChanged(_:)))
        let login = NSButton(checkboxWithTitle: "Launch at Login",
                             target: self, action: #selector(loginCheckboxChanged(_:)))
        forwardCheckbox = fwd; autoWakeCheckbox = aw; loginCheckbox = login

        let shortcuts = NSTextField(wrappingLabelWithString:
            "F10 / F11 / F12 control the M9 only while it is the Mac's sound output; " +
            "otherwise they control the Mac as usual. OK / Back / Home / Power are in the menu.")
        shortcuts.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        shortcuts.textColor = .secondaryLabelColor
        shortcuts.isSelectable = false
        shortcuts.widthAnchor.constraint(equalToConstant: 320).isActive = true   // 360 − insets → wraps

        for v in [settingsHeading("Monitor"), statusLabel, macLabel, rescanBtn,
                  settingsHeading("Options"), fwd, aw, login,
                  settingsHeading("Shortcuts"), shortcuts] {
            stack.addArrangedSubview(v)
        }

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 360),
        ])
        container.layoutSubtreeIfNeeded()

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: container.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "My MacMonitor Settings"
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.center()
        return window
    }

    private func settingsHeading(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        return l
    }

    /// Two-way sync: re-read every state into the Settings controls. Called on open, from
    /// refreshMenu when the window is visible (which the remote.onUpdate path drives).
    private func refreshSettingsUI() {
        guard settingsWindow != nil else { return }
        settingsStatusLabel?.stringValue = statusString()
        settingsMacLabel?.stringValue = UserDefaults.standard.string(forKey: "m9_wifi_mac") ?? "—"
        forwardCheckbox?.state = (forwardingEnabled && AXIsProcessTrusted()) ? .on : .off  // same gate as the menu
        autoWakeCheckbox?.state = autoWakeEnabled ? .on : .off
        loginCheckbox?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    // About panel -------------------------------------------------------------

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)     // .accessory app must activate to show the panel
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let credits = NSAttributedString(string:
            "Forwards the Mac keyboard's volume/mute keys to a Samsung Smart Monitor M9 " +
            "over its Wi-Fi remote, only while the M9 is the sound output.\n\n" +
            "Hardened fork of omarozt/M9Volume @ 496855f by GeRevolver.",
            attributes: attrs)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "My MacMonitor",
        ])
    }
    /// Smart power: toggle over the live socket, else run the wake sequence (WoL + guarded
    /// power). Never queues KEY_POWER — see M9Remote.sendPowerIfConnected.
    @objc private func powerToggle() {
        if remote.connected { remote.sendPowerIfConnected() }
        else { remote.wakeMonitor() }
    }
    @objc private func rescan()  { remote.rescan() }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    // Event tap ---------------------------------------------------------------

    private func promptAccessibilityIfNeeded() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private func createTap() {
        guard eventTap == nil, AXIsProcessTrusted() else { return }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            // NSSystemDefined (14) only: media/volume keys. No keyDown — the app never sees
            // ordinary typing.
            eventsOfInterest: CGEventMask(1 << 14),
            callback: mediaKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        // forwardingEnabled and the M9-is-the-output check gate the swallow inside the callback.
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func reenableTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func relaunchSelf() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point ---------------------------------------------------------

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
