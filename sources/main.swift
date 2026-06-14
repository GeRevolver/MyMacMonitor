// main.swift — M9 Volume (menu-bar agent)
//
// Forwards the Mac keyboard's volume up / down / mute keys to a Samsung Smart
// Monitor M9 over its Wi-Fi WebSocket remote. Menu-bar only, no Dock icon.
//
// This build adds:
//   * IP auto-discovery (remembers last IP; sweeps the /24 to find the M9 by model)
//   * Faster reconnect (proactive, with backoff; reconnects on system wake; and
//     re-discovers the IP if it keeps failing — e.g. DHCP gave it a new address)
//   * "Launch at Login" toggle (SMAppService) — works once it's a real .app
//
// Build it into a signed /Applications app with the accompanying build.sh.
// Quick compile-check first:  swiftc main.swift -o /tmp/m9 -framework Cocoa

import Cocoa
import ServiceManagement

// MARK: - WebSocket remote + discovery ---------------------------------------

final class M9Remote: NSObject, URLSessionWebSocketDelegate {
    static let clientName = "M9Volume"
    static let modelKeyword = "M9"            // matches modelName: 32" Smart Monitor M9
    private let ipKey = "m9_last_ip"
    private let tokenURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".m9volume_token")

    private(set) var ip: String?
    private(set) var connected = false
    var onUpdate: (() -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var connecting = false
    private var reconnectScheduled = false
    private var attempts = 0
    private var pending: [String] = []
    private var sweeping = false

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    // Discovery ---------------------------------------------------------------

    func start() {
        if let saved = UserDefaults.standard.string(forKey: ipKey) {
            verify(saved) { [weak self] ok in
                guard let self = self else { return }
                if ok { self.setIP(saved); self.connect() } else { self.sweep() }
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

    /// GET http://IP:8001/api/v2/ and check the model — confirms it's the M9.
    private func verify(_ ip: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://\(ip):8001/api/v2/") else { completion(false); return }
        var req = URLRequest(url: url); req.timeoutInterval = 2
        session.dataTask(with: req) { data, _, _ in
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            completion(body.contains(Self.modelKeyword))
        }.resume()
    }

    func sweep() {
        guard !sweeping, let base = Self.localSubnetBase() else { return }
        sweeping = true
        DispatchQueue.main.async { self.onUpdate?() }      // shows "searching…"
        let group = DispatchGroup()
        let lock = NSLock()
        var found: String?
        for i in 1...254 {
            let candidate = "\(base).\(i)"
            group.enter()
            verify(candidate) { ok in
                if ok { lock.lock(); if found == nil { found = candidate }; lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.sweeping = false
            if let ip = found { self.setIP(ip); self.attempts = 0; self.connect() }
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
        guard !connected, !connecting, let ip = ip else { return }
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
                try? token.write(to: tokenURL, atomically: true, encoding: .utf8)
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

    func rescan() {
        UserDefaults.standard.removeObject(forKey: ipKey)
        connected = false; connecting = false; task = nil; attempts = 0
        sweep()
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

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
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

    if type.rawValue == 14, app.forwardingEnabled,              // 14 == NSSystemDefined
       let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
        let data1 = ns.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyState = (data1 & 0x0000FF00) >> 8                // 0x0A down
        if keyCode == 0 || keyCode == 1 || keyCode == 7 {       // up / down / mute
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

// MARK: - App delegate / menu bar --------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate {
    let remote = M9Remote()
    var forwardingEnabled = true

    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        remote.onUpdate = { [weak self] in self?.refreshMenu() }
        remote.start()

        promptAccessibilityIfNeeded()
        createTap()
        if eventTap == nil {
            permTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                if AXIsProcessTrusted() {
                    self.createTap(); self.refreshMenu()
                    if self.eventTap != nil { t.invalidate() }
                }
            }
        }

        // Reconnect promptly when the Mac (and likely the monitor) wakes.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.remote.reconnectNow() }

        refreshMenu()
    }

    // Menu --------------------------------------------------------------------

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "M9 Volume") {
                button.image = img
            } else { button.title = "M9" }
        }
        statusItem.menu = NSMenu()
    }

    private func refreshMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let status: String
        if let ip = remote.ip { status = remote.connected ? "M9 — connected (\(ip))" : "M9 — \(ip) (offline)" }
        else { status = "M9 — searching…" }
        let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
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

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        let actions: [(String, Selector)] = [
            ("Volume Up", #selector(volUp)), ("Volume Down", #selector(volDown)),
            ("Mute (toggle)", #selector(mute)), ("Unmute", #selector(unmute)),
        ]
        for (t, sel) in actions {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: ""); it.target = self
            menu.addItem(it)
        }

        menu.addItem(.separator())
        let rescan = NSMenuItem(title: "Rescan for monitor", action: #selector(rescan), keyEquivalent: "")
        rescan.target = self
        menu.addItem(rescan)
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    @objc private func toggleForwarding() {
        forwardingEnabled.toggle()
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: forwardingEnabled) }
        else if forwardingEnabled { createTap() }
        refreshMenu()
    }
    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert(); a.messageText = "Launch at Login failed"
            a.informativeText = "\(error.localizedDescription)\n\nThis works when run as M9Volume.app in /Applications."
            a.runModal()
        }
        refreshMenu()
    }
    @objc private func volUp()   { remote.send("KEY_VOLUP") }
    @objc private func volDown() { remote.send("KEY_VOLDOWN") }
    @objc private func mute()    { remote.send("KEY_MUTE") }
    @objc private func unmute()  { remote.forceUnmute() }
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
            eventsOfInterest: CGEventMask(1 << 14),
            callback: mediaKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: forwardingEnabled)
    }

    func reenableTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}

// MARK: - Entry point ---------------------------------------------------------

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
