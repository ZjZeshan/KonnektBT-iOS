// KonnektBT/Bluetooth/BluetoothBridge.swift
//
// Single-connection state machine. Only ONE connection can exist at a time.
// All state mutations happen on mainQueue. All socket I/O on ioQueue.
// FIXED: Timestamp handling, send error reporting, IP validation
//
import Foundation
import Network

// MARK: - Models
struct CallPacket { let callId, caller, number: String }

struct SMSPacket: Identifiable {
    let id = UUID()
    let sender, number, body: String
    let timestamp: TimeInterval
    let isHistory: Bool

    // FIXED: Handle both seconds and milliseconds consistently
    private static let epochYear1970: TimeInterval = 946684800 // Unix epoch
    var date: Date {
        // If timestamp is before 2000, it's likely milliseconds
        // If timestamp is after 2000 but before 2030, it's likely seconds
        // Timestamps after 2030 in seconds would be year ~2096, unlikely
        let timestampInSeconds: TimeInterval
        if timestamp < 946684800 { // Before Jan 1, 2000 in seconds
            timestampInSeconds = timestamp / 1000.0
        } else if timestamp < 2114380800 { // Before year 2037
            timestampInSeconds = timestamp
        } else {
            timestampInSeconds = timestamp / 1000.0
        }
        return Date(timeIntervalSince1970: timestampInSeconds)
    }
}

// MARK: - Bridge
class BluetoothBridge: NSObject, ObservableObject {

    // ── Constants ─────────────────────────────────────────────────────────
    static let bonjourType  = "_konnekt._tcp"
    static let bonjourPort: UInt16 = 43210
    private static let MARK_JSON:  UInt8 = 0xAC
    private static let MARK_AUDIO: UInt8 = 0xAB

    // ── Public state (main thread only) ───────────────────────────────────
    @Published var isConnected    = false
    @Published var localIPAddress = "Detecting..."

    // FIXED: Added error callback for send failures
    var onCallIncoming:  ((CallPacket) -> Void)?
    var onCallEnded:     (() -> Void)?
    var onSMSReceived:   ((SMSPacket) -> Void)?
    var onAudioReceived: ((Data) -> Void)?
    var onSendError:     ((String) -> Void)?

    // ── Private – main thread ─────────────────────────────────────────────
    private enum State { case idle, connecting, connected }
    private var state:          State          = .idle
    private var browser:        NWBrowser?
    private var pathMonitor:    NWPathMonitor?
    private var lastEndpoint:   NWEndpoint?
    private var reconnectWork:  DispatchWorkItem?
    private var lastCallId      = ""

    // ── Private – io thread ───────────────────────────────────────────────
    private let ioQ   = DispatchQueue(label: "konnekt.io",   qos: .userInitiated)
    private var conn: NWConnection?
    private var buf   = Data()

    // ─────────────────────────────────────────────────────────────────────
    override init() {
        super.init()
        refreshLocalIP()
        startPathMonitor()
    }

    // MARK: - Local IP

    func refreshLocalIP() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ip = Self.localIP()
            DispatchQueue.main.async { self?.localIPAddress = ip ?? "No network" }
        }
    }

    private static func localIP() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let base = ifap else { return nil }
        defer { freeifaddrs(base) }
        var table = [String: String]()
        var ptr = base
        while true {
            let ifa = ptr.pointee
            if ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: ifa.ifa_name)
                var addr = ifa.ifa_addr.pointee
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(&addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                            &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                if !ip.hasPrefix("127.") && !ip.isEmpty { table[name] = ip }
            }
            guard let next = ifa.ifa_next else { break }
            ptr = next
        }
        // FIXED: Expanded interface list
        for iface in ["en0","en1","en2","en3","en4","ap0","bridge100","bridge101","pdp_ip0","pdp_ip1","utun0","utun1","awdl0"] {
            if let ip = table[iface] { return ip }
        }
        return table.values.first { $0.hasPrefix("192.168.") || $0.hasPrefix("10.") || $0.hasPrefix("172.") }
    }

    // MARK: - Path Monitor

    private func startPathMonitor() {
        let mon = NWPathMonitor()
        mon.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.refreshLocalIP()
                if path.status == .satisfied {
                    // Only react to going online if we have somewhere to connect
                    if self.state == .idle, self.lastEndpoint != nil {
                        self.scheduleReconnect(delay: 2)
                    }
                } else {
                    // Network lost — reset to idle
                    self.teardown(reconnect: false)
                }
            }
        }
        mon.start(queue: DispatchQueue(label: "konnekt.netpath"))
        pathMonitor = mon
    }

    // MARK: - Discovery

    func startDiscovery() {
        assert(Thread.isMainThread)
        // Stop old browser
        browser?.cancel()
        browser = nil

        let b = NWBrowser(for: .bonjour(type: Self.bonjourType, domain: nil), using: .tcp)
        b.stateUpdateHandler = { [weak self] s in
            if case .failed = s {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    self?.startDiscovery()
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let ep = results.first?.endpoint else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lastEndpoint = ep
                // Only connect if not already connecting/connected
                if self.state == .idle { self.connect(to: ep) }
            }
        }
        browser = b
        b.start(queue: DispatchQueue(label: "konnekt.browser"))
    }

    // FIXED: Added IP validation
    private func isValidIPAddress(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let num = Int(part) else { return false }
            return num >= 0 && num <= 255
        }
    }

    func connectToIP(_ ip: String, port: UInt16 = bonjourPort) {
        assert(Thread.isMainThread)

        // FIXED: Validate IP before connecting
        guard isValidIPAddress(ip) else {
            print("[Bridge] Invalid IP address: \(ip)")
            onSendError?("Invalid IP address: \(ip)")
            return
        }

        let ep = NWEndpoint.hostPort(host: .init(ip), port: .init(integerLiteral: port))
        lastEndpoint = ep
        // Force a fresh connection even if one exists
        teardown(reconnect: false)
        connect(to: ep)
    }

    // MARK: - Core connect (main thread, state-guarded)

    private func connect(to endpoint: NWEndpoint) {
        assert(Thread.isMainThread)
        guard state == .idle else {
            print("[Bridge] connect() ignored — state=\(state)")
            return
        }
        state = .connecting
        cancelReconnect()

        let c = NWConnection(to: endpoint, using: .tcp)
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self = self else { return }
            switch s {
            case .ready:
                DispatchQueue.main.async {
                    guard self.state == .connecting else { return }
                    self.state       = .connected
                    self.isConnected = true
                    // Start reading on io queue
                    if let conn = c { self.readLoop(conn: conn) }
                    self.sendPacket(["type": "PING"])
                }

            case .failed(let e):
                print("[Bridge] Failed: \(e)")
                DispatchQueue.main.async {
                    guard self.state != .idle else { return }
                    self.teardown(reconnect: true)
                }

            case .waiting(let e):
                // Waiting usually means the address is unreachable yet
                // Give it 8s before giving up and retrying
                print("[Bridge] Waiting: \(e)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self = self, self.state == .connecting else { return }
                    self.teardown(reconnect: true)
                }

            case .cancelled:
                // Only act on unexpected cancellations
                DispatchQueue.main.async {
                    guard self.state != .idle else { return }
                    self.teardown(reconnect: true)
                }

            case .preparing: break
            @unknown default: break
            }
        }

        // Store + start on io queue
        ioQ.async { [weak self] in
            guard let self = self else { return }
            self.conn = c
            self.buf.removeAll()
            c.start(queue: self.ioQ)
        }
    }

    // MARK: - Read loop (io queue)

    private func readLoop(conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, done, err in
            guard let self = self else { return }

            if let err = err {
                let code = (err as NSError).code
                if code != 57 && code != 54 { print("[Bridge] Recv \(code)") }
                DispatchQueue.main.async { self.teardown(reconnect: true) }
                return
            }

            if let data = data, !data.isEmpty {
                self.buf.append(data)
                self.parse()
            }

            if done {
                DispatchQueue.main.async { self.teardown(reconnect: true) }
                return
            }

            // Continue only if this is still the active connection
            if conn === self.conn { self.readLoop(conn: conn) }
        }
    }

    // MARK: - Parse (io queue)

    private func parse() {
        if buf.count > 10_000_000 { buf.removeAll(); return }

        while buf.count >= 5 {
            let marker = buf[0]
            let len = (Int(buf[1]) << 24) | (Int(buf[2]) << 16)
                    | (Int(buf[3]) <<  8) |  Int(buf[4])

            guard len > 0, len <= 2_000_000 else {
                // Bad length — resync: scan forward for next marker byte
                var found = false
                for i in 1 ..< buf.count {
                    if buf[i] == Self.MARK_JSON || buf[i] == Self.MARK_AUDIO {
                        buf.removeFirst(i)
                        found = true
                        break
                    }
                }
                if !found { buf.removeAll() }
                return
            }

            guard buf.count >= 5 + len else { break }

            let payload = buf.subdata(in: 5 ..< 5 + len)
            buf.removeFirst(5 + len)

            switch marker {
            case Self.MARK_JSON:
                if let s = String(data: payload, encoding: .utf8) {
                    dispatchJSON(s)
                }
            case Self.MARK_AUDIO:
                let copy = payload
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.isConnected else { return }
                    self.onAudioReceived?(copy)
                }
            default:
                buf.removeFirst(1) // skip unknown byte, try next
            }
        }
    }

    // MARK: - JSON (io queue → main)

    private func dispatchJSON(_ json: String) {
        guard let raw  = json.data(using: .utf8),
              let obj  = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let type = obj["type"] as? String else {
            print("[Bridge] Bad JSON: \(json.prefix(80))")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isConnected else { return }

            switch type {
            case "CALL_INCOMING":
                let id = obj["callId"] as? String ?? UUID().uuidString
                guard id != self.lastCallId else { return }
                self.lastCallId = id
                self.onCallIncoming?(CallPacket(
                    callId: id,
                    caller: obj["caller"]      as? String
                         ?? obj["name"]        as? String ?? "Unknown",
                    number: obj["number"]      as? String
                         ?? obj["phoneNumber"] as? String ?? ""))

            case "CALL_ENDED", "CALL_END", "CALL_DISCONNECTED":
                self.lastCallId = ""
                self.onCallEnded?()

            case "SMS_RECEIVED", "SMS_HISTORY", "SMS", "MESSAGE":
                // FIXED: Normalize timestamp to milliseconds for consistency
                var timestamp = obj["timestamp"] as? TimeInterval ?? 0
                // If timestamp is in seconds (less than year 2037 in seconds), convert to ms
                if timestamp > 0 && timestamp < 2114380800 {
                    timestamp *= 1000
                }

                self.onSMSReceived?(SMSPacket(
                    sender:    obj["sender"]    as? String
                            ?? obj["name"]      as? String ?? "Unknown",
                    number:    obj["number"]    as? String
                            ?? obj["from"]      as? String ?? "",
                    body:      obj["body"]      as? String
                            ?? obj["message"]   as? String ?? "",
                    timestamp: timestamp > 0 ? timestamp : Date().timeIntervalSince1970 * 1000,
                    isHistory: type == "SMS_HISTORY"))

            case "PING":  self.sendPacket(["type": "PONG"])
            case "PONG", "ACK", "STATUS": break
            default: print("[Bridge] Unknown: \(type)")
            }
        }
    }

    // MARK: - Send (any thread)

    // FIXED: Added completion handler for error reporting
    func sendPacket(_ dict: [String: Any], completion: ((Error?) -> Void)? = nil) {
        guard let json = try? JSONSerialization.data(withJSONObject: dict) else {
            let error = NSError(domain: "BluetoothBridge", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize JSON"])
            completion?(error)
            onSendError?("Failed to serialize: \(dict)")
            return
        }
        send(marker: Self.MARK_JSON, payload: json, completion: completion)
    }

    func sendAudioFrame(_ pcm: Data) {
        send(marker: Self.MARK_AUDIO, payload: pcm, completion: nil)
    }

    private func send(marker: UInt8, payload: Data, completion: ((Error?) -> Void)?) {
        var f = Data(capacity: 5 + payload.count)
        f.append(marker)
        let l = payload.count
        f.append(contentsOf: [UInt8((l>>24)&0xFF), UInt8((l>>16)&0xFF),
                               UInt8((l>>8)&0xFF),  UInt8(l&0xFF)])
        f.append(payload)

        ioQ.async { [weak self] in
            guard let conn = self?.conn else {
                let error = NSError(domain: "BluetoothBridge", code: -2, userInfo: [NSLocalizedDescriptionKey: "No connection"])
                DispatchQueue.main.async {
                    completion?(error)
                    self?.onSendError?("No connection available")
                }
                return
            }

            conn.send(content: f, completion: .contentProcessed { error in
                DispatchQueue.main.async {
                    completion?(error)
                    if let error = error {
                        self?.onSendError?("Send failed: \(error.localizedDescription)")
                    }
                }
            })
        }
    }

    func sendCallAnswered() { sendPacket(["type": "CALL_ANSWERED"]) }
    func sendCallRejected() { sendPacket(["type": "CALL_REJECTED"]) }
    func sendCallEnded()    { sendPacket(["type": "CALL_ENDED"])    }
    func sendSMS(to n: String, body: String) {
        sendPacket(["type": "SEND_SMS", "to": n, "body": body])
    }

    // MARK: - Teardown (main thread)

    private func teardown(reconnect: Bool) {
        assert(Thread.isMainThread)
        guard state != .idle else { return }

        isConnected = false
        state       = .idle

        // Cancel socket on io queue
        ioQ.async { [weak self] in
            self?.conn?.cancel()
            self?.conn = nil
            self?.buf.removeAll()
        }

        if reconnect { scheduleReconnect(delay: 4) }
    }

    // MARK: - Reconnect

    private func scheduleReconnect(delay: TimeInterval) {
        assert(Thread.isMainThread)
        cancelReconnect()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.state == .idle else { return }
            if let ep = self.lastEndpoint { self.connect(to: ep) }
            else { self.startDiscovery() }
        }
        reconnectWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelReconnect() {
        reconnectWork?.cancel()
        reconnectWork = nil
    }

    // MARK: - Public disconnect

    func disconnect() {
        assert(Thread.isMainThread)
        cancelReconnect()
        browser?.cancel();     browser     = nil
        pathMonitor?.cancel(); pathMonitor = nil
        teardown(reconnect: false)
    }
}
