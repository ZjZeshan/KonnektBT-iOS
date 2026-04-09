// KonnektBT/Bluetooth/BluetoothBridge.swift
//
// iPhone-to-Android Bridge for Calls & SMS
// Connection: WiFi Direct (TCP Socket)
// Uses Bonjour discovery + direct IP fallback
//
import Foundation
import Network

// File-based logger
let bridgeLogger = Logger.shared

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
            bridgeLogger.log(msg, category: "BRIDGE")
        }
    }

    private func updateError(_ msg: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = msg
            self?.onConnectionError?(msg)
            bridgeLogger.error(msg)
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
            bridgeLogger.log("Already connected, ignoring", category: "BRIDGE")
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
                bridgeLogger.log("Connection .ready received", category: "BRIDGE")
                // CRASH FIX: Capture connection before async dispatch
                let connCopy = connection
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { 
                        bridgeLogger.log("CRASH: self nil in .ready handler", category: "BRIDGE")
                        return 
                    }
                    // Additional safety - verify we're in a valid state to connect
                    guard self.state == .connecting || self.state == .searching || self.state == .idle else {
                        bridgeLogger.log("Already connected or invalid state, ignoring", category: "BRIDGE")
                        return
                    }
                    bridgeLogger.log("Setting state to connected, starting readLoop and sending HANDSHAKE", category: "BRIDGE")
                    self.state = .connected
                    self.isConnected = true
                    self.updateStatus("Connected!")
                    self.lastError = nil
                    
                    // CRASH FIX: Start readLoop with captured connection
                    bridgeLogger.log("Starting readLoop...", category: "BRIDGE")
                    self.readLoop(conn: connCopy)
                    
                    // CRASH FIX: Send handshake
                    bridgeLogger.log("Sending HANDSHAKE...", category: "BRIDGE")
                    self.sendPacket(["type": "HANDSHAKE", "platform": "ios", "version": "2.8"])
                    bridgeLogger.log("HANDSHAKE sent", category: "BRIDGE")
                }

            case .failed(let err):
                bridgeLogger.log("Connection failed: \(err)", category: "BRIDGE")
                DispatchQueue.main.async {
                    self.updateError("Connection failed: \(err.localizedDescription)")
                    self.state = .idle
                    self.isConnected = false
                    self.scheduleReconnect()
                }

            case .waiting(let err):
                bridgeLogger.log("Waiting: \(err)", category: "BRIDGE")
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
        bridgeLogger.log("readLoop started", category: "BRIDGE")
        
        // Safety check - don't read if we're not in connected state
        guard state == .connected else { 
            bridgeLogger.log("readLoop: state not connected, exiting", category: "BRIDGE")
            return 
        }
        
        // CRASH FIX: Capture conn to prevent deallocation
        let connection = conn
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self = self else { 
                bridgeLogger.log("CRASH: self nil in receive callback", category: "BRIDGE")
                return 
            }
            
            bridgeLogger.log("receive callback fired", category: "BRIDGE")
            
            // Additional safety check - verify this connection is still the active one
            guard connection === self.conn else {
                bridgeLogger.log("Stale connection callback, ignoring", category: "BRIDGE")
                return
            }

            if let err = err {
                let code = (err as NSError).code
                // Ignore common disconnect codes (57 = socket closed, 54 = connection reset)
                if code != 57 && code != 54 {
                    bridgeLogger.log("Receive error: \(code)", category: "BRIDGE")
                }
                DispatchQueue.main.async {
                    self.updateError("Connection lost")
                    self.teardown()
                }
                return
            }

            if let data = data, !data.isEmpty {
                bridgeLogger.log("Received data: \(data.count) bytes", category: "BRIDGE")
                // Limit buffer size to prevent memory issues
                let newSize = self.buf.count + data.count
                if newSize > 10_000_000 {
                    bridgeLogger.log("Buffer overflow, clearing", category: "BRIDGE")
                    self.buf.removeAll()
                    return
                }
                self.buf.append(data)
                bridgeLogger.log("Calling parse()...", category: "BRIDGE")
                self.parse()
                bridgeLogger.log("parse() completed", category: "BRIDGE")
            }

            if done {
                bridgeLogger.log("Connection done", category: "BRIDGE")
                DispatchQueue.main.async {
                    self.updateStatus("Connection closed")
                    self.teardown()
                }
                return
            }

            // Continue reading only if this is still the active connection
            if connection === self.conn && self.state == .connected {
                bridgeLogger.log("Calling readLoop recursively...", category: "BRIDGE")
                self.readLoop(conn: connection)
            }
        }
    }

    // MARK: - Parse

    private func parse() {
        // Safety check - ensure we have enough data
        guard buf.count >= 5 else { return }

        // Guard against buffer overflow
        if buf.count > 10_000_000 {
            bridgeLogger.log("Buffer overflow, clearing", category: "BRIDGE")
            buf.removeAll()
            return
        }

        while buf.count >= 5 {
            // Additional safety - verify we have valid buffer access
            guard buf.count > 0 else { break }
            
            let marker = buf[0]
            let len = (Int(buf[1]) << 24) | (Int(buf[2]) << 16) | (Int(buf[3]) << 8) | Int(buf[4])

            // Validate length
            guard len > 0, len <= 1_000_000 else {
                bridgeLogger.log("Invalid packet length: \(len)", category: "BRIDGE")
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

            // Check if we have complete packet
            guard buf.count >= 5 + len else { break }

            // CRASH SAFETY: Wrap entire packet processing in do-catch
            do {
                // Extract payload safely
                let payload = buf.subdata(in: 5..<(5+len))
                
                buf.removeFirst(5 + len)

                switch marker {
                case Self.MARK_JSON:
                    bridgeLogger.log("Received JSON packet, length=\(len)", category: "PARSE")
                    if let s = String(data: payload, encoding: .utf8) {
                        bridgeLogger.log("JSON string: \(s.prefix(200))", category: "PARSE")
                        dispatchJSON(s)
                    } else {
                        bridgeLogger.log("Failed to decode JSON as UTF8", category: "PARSE")
                    }
                case Self.MARK_AUDIO:
                    bridgeLogger.log("Received AUDIO packet, length=\(len)", category: "AUDIO")
                    let copy = payload
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.isConnected else { return }
                        self.onAudioReceived?(copy)
                    }
                default:
                    // Unknown marker, skip it
                    bridgeLogger.log("Unknown marker: 0x\(String(marker, radix: 16))", category: "PARSE")
                    if !buf.isEmpty {
                        buf.removeFirst(1)
                    }
                }
            } catch {
                bridgeLogger.log("Parse error: \(error), clearing buffer", category: "PARSE")
                buf.removeAll()
                return
            }
        }
    }

    // MARK: - Dispatch JSON

    private func dispatchJSON(_ json: String) {
        bridgeLogger.log("dispatchJSON called with: \(json.prefix(200))", category: "PACKET")
        guard let raw = json.data(using: .utf8) else {
            bridgeLogger.log("dispatchJSON: Failed to convert to data", category: "PACKET")
            return
        }
        
        guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            bridgeLogger.log("dispatchJSON: Failed to parse JSON", category: "PACKET")
            return
        }
        
        guard let type = obj["type"] as? String else {
            bridgeLogger.log("dispatchJSON: No 'type' field in JSON", category: "PACKET")
            return
        }

        bridgeLogger.log("dispatchJSON: type=\(type), dispatching to main thread", category: "PACKET")

        // CRASH FIX: Wrap in do-catch and use weak self
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                bridgeLogger.log("CRASH: self nil in dispatchJSON callback", category: "PACKET")
                return
            }
            bridgeLogger.log("handlePacket: \(type) - on main thread", category: "PACKET")
            self.handlePacket(type: type, obj: obj)
            bridgeLogger.log("handlePacket completed", category: "PACKET")
        }
    }
    
    // Handle packets
    private func handlePacket(type: String, obj: [String: Any]) {
        bridgeLogger.log("handlePacket: \(type)", category: "PACKET")
        
        // CRASH SAFETY: Wrap each case in do-catch
        do {
            switch type {
            case "HANDSHAKE":
                let platform = obj["platform"] as? String ?? "unknown"
                bridgeLogger.log("HANDSHAKE from Android: platform=\(platform)", category: "PACKET")
                updateStatus("Android connected!")
                sendPacket([
                    "type": "HANDSHAKE",
                    "platform": "ios",
                    "version": "2.8"
                ])
                bridgeLogger.log("HANDSHAKE response sent", category: "PACKET")

            case "HANDSHAKE_ACK":
                bridgeLogger.log("HANDSHAKE_ACK received", category: "PACKET")
                updateStatus("Connected & Synced!")

            case "CALL_INCOMING":
                bridgeLogger.log("CALL_INCOMING packet", category: "PACKET")
                let id = obj["callId"] as? String ?? UUID().uuidString
                guard id != lastCallId else { 
                    bridgeLogger.log("Duplicate call ignored", category: "PACKET")
                    return
                }
                lastCallId = id

                let caller = obj["caller"] as? String ?? obj["name"] as? String ?? "Unknown"
                let number = obj["number"] as? String ?? obj["phoneNumber"] as? String ?? ""
                updateStatus("Incoming call from \(caller)")
                
                // Safely invoke callback with validated data
                let packet = CallPacket(callId: id, caller: caller, number: number)
                bridgeLogger.log("Calling onCallIncoming callback", category: "PACKET")
                onCallIncoming?(packet)
                bridgeLogger.log("onCallIncoming callback completed", category: "PACKET")

            case "CALL_ENDED", "CALL_END", "CALL_DISCONNECTED":
                bridgeLogger.log("Call ended packet: \(type)", category: "PACKET")
                lastCallId = ""
                bridgeLogger.log("Calling onCallEnded callback", category: "PACKET")
                onCallEnded?()
                bridgeLogger.log("onCallEnded callback completed", category: "PACKET")

            case "SMS_RECEIVED", "SMS_HISTORY", "SMS", "MESSAGE":
                bridgeLogger.log("SMS packet: \(type)", category: "PACKET")
                var ts = obj["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
                if ts < 946684800 { ts *= 1000 }
                if ts > 2114380800 { ts /= 1000 }

                let sender = obj["sender"] as? String ?? obj["name"] as? String ?? "Unknown"
                let number = obj["number"] as? String ?? obj["from"] as? String ?? ""
                let body = obj["body"] as? String ?? obj["message"] as? String ?? ""

                let packet = SMSPacket(
                    sender: sender, number: number, body: body,
                    timestamp: ts, isHistory: type == "SMS_HISTORY")
                bridgeLogger.log("Calling onSMSReceived callback", category: "PACKET")
                onSMSReceived?(packet)
                bridgeLogger.log("onSMSReceived callback completed", category: "PACKET")

            case "HEARTBEAT", "PING":
                bridgeLogger.log("Heartbeat/Ping received", category: "PACKET")
                sendPacket(["type": "PONG"])
                
            case "PONG", "ACK", "SYNC_COMPLETE":
                bridgeLogger.log("ACK received: \(type)", category: "PACKET")
                break
                
            case "AUDIO_START", "AUDIO_STOP", "STREAM_START", "STREAM_STOP":
                bridgeLogger.log("Audio control: \(type)", category: "PACKET")
                // Audio control messages - no-op, handled by audio manager
                break
            
            case "DEVICE_INFO", "BATTERY", "NETWORK_STATUS":
                bridgeLogger.log("Device info: \(type)", category: "PACKET")
                break
                
            default:
                bridgeLogger.log("Unknown packet type: \(type)", category: "PACKET")
            }
            bridgeLogger.log("handlePacket: \(type) completed successfully", category: "PACKET")
        } catch {
            bridgeLogger.log("handlePacket error: \(error)", category: "PACKET")
        }
    }

    // MARK: - Send

    func sendPacket(_ dict: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: dict) else {
            bridgeLogger.log("JSON encode failed", category: "SEND")
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
                    bridgeLogger.log("Send error: \(err)", category: "SEND")
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
