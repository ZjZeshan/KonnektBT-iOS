// KonnektBT/Bluetooth/BluetoothBridge.swift
//
// iPhone-to-Android Bridge for Calls & SMS
// Connection: WiFi Direct (TCP Socket)
// Uses Bonjour discovery + direct IP fallback
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

    var date: Date {
        let ts = timestamp < 946684800 ? timestamp / 1000.0 : timestamp
        return Date(timeIntervalSince1970: ts)
    }
}

// MARK: - Connection Bridge
class BluetoothBridge: NSObject, ObservableObject {

    // Connection Constants
    static let bonjourType = "_konnekt._tcp"
    static let bonjourName = "KonnektAndroid"
    static let bonjourPort: UInt16 = 43210
    private static let MARK_JSON: UInt8 = 0xAC
    private static let MARK_AUDIO: UInt8 = 0xAB

    // Public State
    @Published var isConnected = false
    @Published var localIPAddress = "Detecting..."
    @Published var connectionStatus = "Ready"
    @Published var lastError: String?

    // Callbacks
    var onCallIncoming: ((CallPacket) -> Void)?
    var onCallEnded: (() -> Void)?
    var onSMSReceived: ((SMSPacket) -> Void)?
    var onAudioReceived: ((Data) -> Void)?
    var onConnectionError: ((String) -> Void)?

    // Private State
    private enum State { case idle, searching, connecting, connected }
    private var state: State = .idle
    private var browser: NWBrowser?
    private var pathMonitor: NWPathMonitor?
    private var lastEndpoint: NWEndpoint?
    private var reconnectTimer: Timer?
    private var lastCallId = ""

    // Private - IO Queue
    private let ioQ = DispatchQueue(label: "com.konnekt.io", qos: .userInitiated)
    private var conn: NWConnection?
    private var buf = Data()

    // ───────────────────────────────────────────────────────────────────────
    override init() {
        super.init()
        refreshLocalIP()
        startPathMonitor()
    }

    deinit {
        disconnect()
    }

    // MARK: - Status Updates

    private func updateStatus(_ msg: String) {
        DispatchQueue.main.async { [weak self] in
            self?.connectionStatus = msg
            print("[Konnekt] \(msg)")
        }
    }

    private func updateError(_ msg: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = msg
            self?.onConnectionError?(msg)
            print("[Konnekt ERROR] \(msg)")
        }
    }

    // MARK: - Local IP Detection

    func refreshLocalIP() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ip = Self.getLocalIP()
            DispatchQueue.main.async {
                self?.localIPAddress = ip ?? "No WiFi"
                self?.updateStatus(ip != nil ? "IP: \(ip!)" : "No network")
            }
        }
    }

    private static func getLocalIP() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let base = ifap else { return nil }
        defer { freeifaddrs(base) }

        var table = [String: String]()
        var ptr = base

        while true {
            let ifa = ptr.pointee
            if ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var addr = ifa.ifa_addr.pointee
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(&addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                            &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                let name = String(cString: ifa.ifa_name)
                if !ip.hasPrefix("127.") && !ip.isEmpty {
                    table[name] = ip
                }
            }
            guard let next = ifa.ifa_next else { break }
            ptr = next
        }

        for iface in ["en0", "en1", "en2", "en3", "bridge100", "bridge101"] {
            if let ip = table[iface] { return ip }
        }

        return table.values.first
    }

    // MARK: - Network Path Monitor

    private func startPathMonitor() {
        pathMonitor = NWPathMonitor()
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.refreshLocalIP()

                if path.status == .satisfied {
                    if self.state == .idle {
                        self.updateStatus("Network available")
                    }
                } else {
                    self.updateStatus("Network lost")
                    self.teardown()
                }
            }
        }
        pathMonitor?.start(queue: DispatchQueue(label: "com.konnekt.network"))
    }

    // MARK: - Discovery

    func startDiscovery() {
        guard state == .idle || state == .searching else { return }

        updateStatus("Searching for Android...")
        state = .searching

        browser?.cancel()
        browser = nil

        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: Self.bonjourType, domain: nil), using: params)

        browser.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                self?.updateStatus("Discovery ready")
            case .failed(let err):
                self?.updateError("Discovery failed: \(err.localizedDescription)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self?.startDiscovery()
                }
            case .cancelled:
                self?.updateStatus("Discovery cancelled")
            case .setup:
                self?.updateStatus("Setting up discovery...")
            case .waiting(let err):
                self?.updateStatus("Waiting: \(err.localizedDescription)")
            @unknown default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }

            if let firstResult = results.first {
                let endpoint = firstResult.endpoint
                self.lastEndpoint = endpoint
                self.updateStatus("Found: \(endpoint)")
                self.connect(to: endpoint)
            }
        }

        self.browser = browser
        browser.start(queue: DispatchQueue(label: "com.konnekt.browser"))

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, self.state == .searching else { return }
            self.updateStatus("No auto-discovery. Use manual IP.")
        }
    }

    func connectToIP(_ ip: String, port: UInt16? = nil) {
        let targetPort = port ?? Self.bonjourPort
        updateStatus("Connecting to \(ip)...")

        guard isValidIP(ip) else {
            updateError("Invalid IP: \(ip)")
            return
        }

        browser?.cancel()
        browser = nil

        let endpoint = NWEndpoint.hostPort(host: .init(ip), port: .init(integerLiteral: targetPort))
        lastEndpoint = endpoint
        state = .connecting
        connect(to: endpoint)
    }

    // MARK: - Connection

    private func connect(to endpoint: NWEndpoint) {
        guard state == .searching || state == .connecting || state == .idle else {
            print("[Konnekt] Already connected, ignoring")
            return
        }

        updateStatus("Connecting...")
        state = .connecting

        let params = NWParameters.tcp
        params.prohibitExpensivePaths = false
        params.prohibitedInterfaceTypes = []

        let connection = NWConnection(to: endpoint, using: params)

        connection.stateUpdateHandler = { [weak self] s in
            guard let self = self else { return }

            switch s {
            case .setup:
                break

            case .preparing:
                break

            case .ready:
                DispatchQueue.main.async {
                    self.state = .connected
                    self.isConnected = true
                    self.updateStatus("Connected!")
                    self.lastError = nil
                    self.readLoop(conn: connection)
                    self.sendPacket(["type": "HANDSHAKE", "platform": "ios", "version": "2.8"])
                }

            case .failed(let err):
                print("[Konnekt] Connection failed: \(err)")
                DispatchQueue.main.async {
                    self.updateError("Connection failed: \(err.localizedDescription)")
                    self.state = .idle
                    self.isConnected = false
                    self.scheduleReconnect()
                }

            case .waiting(let err):
                print("[Konnekt] Waiting: \(err)")
                DispatchQueue.main.async {
                    self.updateStatus("Waiting for network...")
                }

            case .cancelled:
                DispatchQueue.main.async {
                    self.updateStatus("Disconnected")
                    self.isConnected = false
                    self.state = .idle
                }

            @unknown default:
                break
            }
        }

        ioQ.async { [weak self] in
            self?.conn = connection
            self?.buf.removeAll()
            connection.start(queue: self?.ioQ ?? DispatchQueue.main)
        }
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.state != .connected {
                self.updateStatus("Retrying connection...")
                if let ep = self.lastEndpoint {
                    self.connect(to: ep)
                } else {
                    self.startDiscovery()
                }
            }
        }
    }

    private func teardown() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil

        ioQ.async { [weak self] in
            self?.conn?.cancel()
            self?.conn = nil
            self?.buf.removeAll()
        }

        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.state = .idle
        }
    }

    // MARK: - Read Loop

    private func readLoop(conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self = self else { return }

            if let err = err {
                let code = (err as NSError).code
                if code != 57 && code != 54 {
                    print("[Konnekt] Receive error: \(code)")
                }
                DispatchQueue.main.async {
                    self.updateError("Connection lost")
                    self.teardown()
                }
                return
            }

            if let data = data, !data.isEmpty {
                self.buf.append(data)
                self.parse()
            }

            if done {
                DispatchQueue.main.async {
                    self.updateStatus("Connection closed")
                    self.teardown()
                }
                return
            }

            if conn === self.conn {
                self.readLoop(conn: conn)
            }
        }
    }

    // MARK: - Parse

    private func parse() {
        guard buf.count >= 5 else { return }

        if buf.count > 10_000_000 {
            buf.removeAll()
            return
        }

        while buf.count >= 5 {
            let marker = buf[0]
            let len = (Int(buf[1]) << 24) | (Int(buf[2]) << 16) | (Int(buf[3]) << 8) | Int(buf[4])

            guard len > 0, len <= 1_000_000 else {
                var found = false
                for i in 1..<min(buf.count, 100) {
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

            let payload = buf.subdata(in: 5..<5+len)
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
                buf.removeFirst(1)
            }
        }
    }

    // MARK: - Dispatch JSON

    private func dispatchJSON(_ json: String) {
        guard let raw = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let type = obj["type"] as? String else {
            print("[Konnekt] Bad JSON: \(json.prefix(80))")
            return
        }

        print("[Konnekt] Received: \(type)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            switch type {
            case "HANDSHAKE":
                let platform = obj["platform"] as? String ?? "unknown"
                print("[Konnekt] Android handshake: platform=\(platform)")
                self.updateStatus("Android connected!")
                self.sendPacket([
                    "type": "HANDSHAKE",
                    "platform": "ios",
                    "version": "2.8"
                ])

            case "HANDSHAKE_ACK":
                self.updateStatus("Connected & Synced!")

            case "CALL_INCOMING":
                let id = obj["callId"] as? String ?? UUID().uuidString
                guard id != self.lastCallId else { return }
                self.lastCallId = id

                let caller = obj["caller"] as? String ?? obj["name"] as? String ?? "Unknown"
                let number = obj["number"] as? String ?? obj["phoneNumber"] as? String ?? ""
                self.updateStatus("Incoming call from \(caller)")
                self.onCallIncoming?(CallPacket(callId: id, caller: caller, number: number))

            case "CALL_ENDED", "CALL_END", "CALL_DISCONNECTED":
                self.lastCallId = ""
                self.onCallEnded?()

            case "SMS_RECEIVED", "SMS_HISTORY", "SMS", "MESSAGE":
                var ts = obj["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
                if ts < 946684800 { ts *= 1000 }
                if ts > 2114380800 { ts /= 1000 }

                let sender = obj["sender"] as? String ?? obj["name"] as? String ?? "Unknown"
                let number = obj["number"] as? String ?? obj["from"] as? String ?? ""
                let body = obj["body"] as? String ?? obj["message"] as? String ?? ""

                self.onSMSReceived?(SMSPacket(
                    sender: sender, number: number, body: body,
                    timestamp: ts, isHistory: type == "SMS_HISTORY"))

            case "HEARTBEAT", "PING":
                self.sendPacket(["type": "PONG"])
            case "PONG", "ACK", "SYNC_COMPLETE":
                break
            default:
                print("[Konnekt] Unknown: \(type)")
            }
        }
    }

    // MARK: - Send

    func sendPacket(_ dict: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: dict) else {
            print("[Konnekt] JSON encode failed")
            return
        }
        send(marker: Self.MARK_JSON, payload: json)
    }

    func sendAudioFrame(_ data: Data) {
        send(marker: Self.MARK_AUDIO, payload: data)
    }

    private func send(marker: UInt8, payload: Data) {
        var frame = Data(capacity: 5 + payload.count)
        frame.append(marker)
        let len = payload.count
        frame.append(contentsOf: [
            UInt8((len >> 24) & 0xFF),
            UInt8((len >> 16) & 0xFF),
            UInt8((len >> 8) & 0xFF),
            UInt8(len & 0xFF)
        ])
        frame.append(payload)

        ioQ.async { [weak self] in
            guard let conn = self?.conn else { return }
            conn.send(content: frame, completion: .contentProcessed { err in
                if let err = err {
                    print("[Konnekt] Send error: \(err)")
                }
            })
        }
    }

    // MARK: - Public API

    func sendCallAnswered() { sendPacket(["type": "CALL_ANSWERED"]) }
    func sendCallRejected() { sendPacket(["type": "CALL_REJECTED"]) }
    func sendCallEnded() { sendPacket(["type": "CALL_ENDED"]) }
    func sendSMS(to number: String, body: String) {
        sendPacket(["type": "SEND_SMS", "to": number, "body": body])
    }

    func disconnect() {
        updateStatus("Disconnecting...")
        reconnectTimer?.invalidate()
        browser?.cancel()
        browser = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        teardown()
        state = .idle
        updateStatus("Disconnected")
    }

    // MARK: - Helpers

    private func isValidIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let num = Int(part), num >= 0, num <= 255 else { return false }
            return true
        }
    }
}
