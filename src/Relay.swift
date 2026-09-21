import Foundation
import Network
import CryptoKit
import CoreGraphics
import AVFoundation

// MARK: - Per-machine settings
//
// Role, name and passcode belong to this Mac, not to the keymap, so they live
// in UserDefaults rather than config.jsonc (which may be shared across Macs).

enum RelayRole: String, CaseIterable {
    case off, host, receiver
    var label: String {
        switch self {
        case .off:      return "关闭"
        case .host:     return "宿主（连着遥控器）"
        case .receiver: return "接收端"
        }
    }
}

enum RelaySettings {
    static let serviceType = "_siriremoted._tcp"
    private static let d = UserDefaults.standard

    /// `--role receiver --name X` override the stored values, so a second
    /// instance can run on the same Mac for a loopback test.
    private static let args: [String: String] = {
        var out: [String: String] = [:]
        let a = CommandLine.arguments
        var i = 1
        while i < a.count {
            if a[i].hasPrefix("--"), i + 1 < a.count { out[String(a[i].dropFirst(2))] = a[i + 1]; i += 2 }
            else { i += 1 }
        }
        return out
    }()

    static var role: RelayRole {
        get { RelayRole(rawValue: args["role"] ?? d.string(forKey: "relay.role") ?? "") ?? .off }
        set { d.set(newValue.rawValue, forKey: "relay.role") }
    }
    static var name: String {
        get { args["name"] ?? d.string(forKey: "relay.name") ?? Host.current().localizedName ?? "Mac" }
        set { d.set(newValue, forKey: "relay.name") }
    }
    static var passcode: String {
        get { args["passcode"] ?? d.string(forKey: "relay.passcode") ?? "" }
        set { d.set(newValue, forKey: "relay.passcode") }
    }
}

// MARK: - Transport
//
// A receiver types whatever it is told to, so an unauthenticated one would let
// anyone on the same Wi-Fi drive this Mac. Every connection is TLS with a key
// derived from the shared passcode; a wrong passcode fails the handshake.

enum RelayCrypto {
    static func parameters(passcode: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = SymmetricKey(data: Data(passcode.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data("siriremoted-relay-v1".utf8), using: key)
        let psk = Data(code).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("siriremoted".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                                                psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true            // keystrokes are tiny and latency-sensitive
        let p = NWParameters(tls: tls, tcp: tcp)
        p.includePeerToPeer = true
        return p
    }
}

/// One line of newline-delimited JSON.
struct RelayMessage: Codable {
    var t: String            // hello | down | up | tap | releaseAll | ping
    var code: UInt16?
    var flags: UInt64?
    var name: String?
}

struct PeerInfo: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let state: String
    let ready: Bool
}

/// What the settings window and menu bar show.
final class RelayStatus: ObservableObject {
    @Published var peers: [PeerInfo] = []
    @Published var current: String?          // nil = this Mac
    @Published var receiverConnections = 0
    @Published var note = ""
}

/// Speaks the target's name on every switch — without it you can't tell
/// which Mac the remote is driving.
final class Announcer {
    private let synth = AVSpeechSynthesizer()
    var enabled: () -> Bool = { true }

    func say(_ text: String) {
        guard enabled() else { return }
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.55
        synth.speak(u)
    }
}

// MARK: - Receiver

final class RelayReceiver {
    private var listener: NWListener?
    private var sessions: [ReceiverSession] = []
    let status: RelayStatus
    var onChange: (() -> Void)?

    init(status: RelayStatus) { self.status = status }

    func start() {
        guard !RelaySettings.passcode.isEmpty else {
            status.note = "还没设置配对码 —— 在 设置 › 多电脑 里填写"
            return
        }
        do {
            let l = try NWListener(using: RelayCrypto.parameters(passcode: RelaySettings.passcode))
            l.service = NWListener.Service(name: RelaySettings.name, type: RelaySettings.serviceType)
            l.stateUpdateHandler = { [weak self] state in
                Log.write("relay listener: \(state)")
                switch state {
                case .ready:          self?.publish()
                case .failed(let e):  self?.status.note = "监听失败：\(e.localizedDescription)"
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.start(queue: .main)
            listener = l
            Log.write("relay: receiver advertising as \"\(RelaySettings.name)\"")
        } catch {
            status.note = "监听失败：\(error)"
            Log.write("relay listener error: \(error)")
        }
    }

    private func accept(_ c: NWConnection) {
        let s = ReceiverSession(conn: c)
        s.onClose = { [weak self, weak s] in
            self?.sessions.removeAll { $0 === s }
            self?.publish()
        }
        s.onReady = { [weak self] in self?.publish() }
        sessions.append(s)
        s.start()
    }

    private func publish() {
        let n = sessions.filter(\.ready).count
        status.receiverConnections = n
        status.note = n > 0 ? "已被宿主机连接" : "等待宿主机连接（本机名字：\(RelaySettings.name)）"
        onChange?()
    }

    func stop() {
        listener?.cancel(); listener = nil
        sessions.forEach { $0.close() }
        sessions = []
    }
}

final class ReceiverSession {
    let conn: NWConnection
    private var buffer = Data()
    private var held: [KeyStroke] = []
    private var lastSeen = Date()
    private var watchdog: Timer?
    private var closed = false
    private(set) var ready = false
    var onClose: (() -> Void)?
    var onReady: (() -> Void)?

    init(conn: NWConnection) { self.conn = conn }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready = true
                Log.write("relay: host connected")
                self.onReady?()
            case .failed(let e):
                Log.write("relay: session failed — \(e)")
                self.close()
            case .cancelled:
                self.close()
            default: break
            }
        }
        conn.start(queue: .main)
        receive()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.ready, !self.closed else { return }
            Log.write("relay: handshake never completed — wrong passcode on the host? closing")
            self.close()
        }
        // A host that vanishes mid push-to-talk would leave right Option stuck
        // down on this Mac. The host pings every 2s; silence while something is
        // held means let go.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.held.isEmpty,
                  Date().timeIntervalSince(self.lastSeen) > 6 else { return }
            Log.write("relay: host went quiet — releasing held keys")
            self.releaseAll()
        }
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { self.buffer.append(data); self.drain() }
            if done || err != nil { self.close(); return }
            self.receive()
        }
    }

    private func drain() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            if let m = try? JSONDecoder().decode(RelayMessage.self, from: line) { handle(m) }
        }
    }

    private func handle(_ m: RelayMessage) {
        lastSeen = Date()
        let k = m.code.map { KeyStroke(code: CGKeyCode($0), flags: CGEventFlags(rawValue: m.flags ?? 0)) }
        switch m.t {
        case "down":       if let k { KeySynth.down(k); held.append(k) }
        case "up":         if let k { KeySynth.up(k); held.removeAll { $0.code == k.code } }
        case "tap":        if let k { KeySynth.tap(k) }
        case "releaseAll": releaseAll()
        case "hello":      Log.write("relay: hello from \(m.name ?? "?")")
        default: break
        }
    }

    private func releaseAll() {
        for k in held { KeySynth.up(k) }
        held = []
    }

    func close() {
        guard !closed else { return }
        closed = true
        releaseAll()
        watchdog?.invalidate()
        conn.cancel()
        onClose?()
    }
}

// MARK: - Host

final class HostPeer {
    let name: String
    let endpoint: NWEndpoint
    private var conn: NWConnection?
    private var pingTimer: Timer?
    private var retry: DispatchWorkItem?
    private var handshakeTimeout: DispatchWorkItem?
    private var closed = false
    private(set) var ready = false
    private(set) var stateText = "连接中…"
    var onChange: (() -> Void)?

    init(name: String, endpoint: NWEndpoint) {
        self.name = name
        self.endpoint = endpoint
    }

    func connect() {
        guard !closed else { return }
        let c = NWConnection(to: endpoint, using: RelayCrypto.parameters(passcode: RelaySettings.passcode))
        conn = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, c === self.conn else { return }
            self.handle(state)
        }
        c.start(queue: .main)
        watchForClose(c)

        // A PSK mismatch doesn't fail the connection promptly — the handshake
        // just stalls. Without a deadline the host would show "connecting"
        // forever and a mistyped passcode would be indistinguishable from a
        // slow network.
        handshakeTimeout?.cancel()
        let w = DispatchWorkItem { [weak self, weak c] in
            guard let self, let c, c === self.conn, !self.ready else { return }
            self.drop("握手超时 —— 多半是两边配对码不一致")
            self.onChange?()
        }
        handshakeTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            handshakeTimeout?.cancel()
            ready = true
            stateText = "已连接"
            send(RelayMessage(t: "hello", name: RelaySettings.name))
            pingTimer?.invalidate()
            pingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.send(RelayMessage(t: "ping"))
            }
            Log.write("relay: connected to \(name)")
        case .waiting(let e), .failed(let e):
            drop(Self.describe(e))
        default:
            break
        }
        onChange?()
    }

    /// The receiver never sends anything we need; reading is only how we learn
    /// that it closed the connection.
    private func watchForClose(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak c] _, _, done, err in
            guard let self, let c, c === self.conn else { return }
            if done || err != nil { self.drop("已断开"); self.onChange?(); return }
            self.watchForClose(c)
        }
    }

    private func drop(_ reason: String) {
        // Log when the reason changes, not on every 3s retry — but always log it
        // once, or a wrong passcode on another Mac is impossible to diagnose.
        if ready || reason != stateText { Log.write("relay: \(name) — \(reason)") }
        ready = false
        stateText = reason
        pingTimer?.invalidate()
        conn?.cancel()
        conn = nil
        scheduleRetry()
    }

    @discardableResult
    func send(_ m: RelayMessage) -> Bool {
        guard ready, let c = conn, var data = try? JSONEncoder().encode(m) else { return false }
        data.append(0x0A)
        c.send(content: data, completion: .contentProcessed { _ in })
        return true
    }

    func close() {
        closed = true
        retry?.cancel()
        handshakeTimeout?.cancel()
        pingTimer?.invalidate()
        conn?.cancel()
        conn = nil
        ready = false
    }

    private func scheduleRetry() {
        guard !closed else { return }
        retry?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.connect() }
        retry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    static func describe(_ e: NWError) -> String {
        if case .tls = e { return "配对码不一致" }
        return "连不上（\(e.localizedDescription)）"
    }
}

final class RelayHost {
    private var browser: NWBrowser?
    private var peers: [String: HostPeer] = [:]
    let status: RelayStatus
    let announcer: Announcer
    var onChange: (() -> Void)?

    /// Where keys go right now; nil = this Mac.
    private(set) var current: String?

    init(status: RelayStatus, announcer: Announcer) {
        self.status = status
        self.announcer = announcer
    }

    var readyNames: [String] { peers.values.filter(\.ready).map(\.name).sorted() }

    func start() {
        guard !RelaySettings.passcode.isEmpty else {
            status.note = "还没设置配对码 —— 在 设置 › 多电脑 里填写"
            return
        }
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: RelaySettings.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        b.stateUpdateHandler = { state in Log.write("relay browser: \(state)") }
        b.start(queue: .main)
        browser = b
        status.note = "正在局域网里找接收端…"
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var seen = Set<String>()
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            seen.insert(name)
            guard peers[name] == nil else { continue }
            let p = HostPeer(name: name, endpoint: r.endpoint)
            p.onChange = { [weak self] in self?.peerChanged(name) }
            peers[name] = p
            Log.write("relay: found \(name)")
            p.connect()
        }
        for (name, p) in peers where !seen.contains(name) {
            p.close()
            peers.removeValue(forKey: name)
            Log.write("relay: \(name) went away")
            peerChanged(name)
        }
        publish()
    }

    private func peerChanged(_ name: String) {
        if current == name, peers[name]?.ready != true {
            current = nil
            Log.write("relay: target \(name) lost — back to this Mac")
            announcer.say("\(name) 断开了，回到本机")
        }
        publish()
    }

    /// "next" / "prev" / "local" / a receiver's name.
    func select(_ spec: String) {
        let order: [String?] = [nil] + readyNames.map { Optional($0) }
        if order.count == 1, spec != "local" {
            announcer.say("没找到其他电脑")
            return
        }
        let idx = order.firstIndex(where: { $0 == current }) ?? 0
        let next: String?
        switch spec {
        case "next":  next = order[(idx + 1) % order.count]
        case "prev":  next = order[(idx - 1 + order.count) % order.count]
        case "local": next = nil
        default:
            guard readyNames.contains(spec) else { announcer.say("找不到 \(spec)"); return }
            next = spec
        }
        // Nothing may stay pressed on the Mac we're leaving.
        if let old = current, old != next { peers[old]?.send(RelayMessage(t: "releaseAll")) }
        current = next
        Log.write("relay: target -> \(next ?? "this Mac")")
        announcer.say(next ?? "本机")
        publish()
    }

    @discardableResult
    func send(to name: String, _ m: RelayMessage) -> Bool {
        peers[name]?.send(m) ?? false
    }

    func stop() {
        browser?.cancel(); browser = nil
        peers.values.forEach { $0.close() }
        peers = [:]
        current = nil
    }

    private func publish() {
        status.peers = peers.values.sorted { $0.name < $1.name }
            .map { PeerInfo(name: $0.name, state: $0.stateText, ready: $0.ready) }
        status.current = current
        status.note = peers.isEmpty ? "正在局域网里找接收端…" : ""
        onChange?()
    }
}
