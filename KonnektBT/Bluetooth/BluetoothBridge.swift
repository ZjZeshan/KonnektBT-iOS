// KonnektBT/Bluetooth/BluetoothBridge.swift
//
// iPhone-to-Android Bridge for Calls & SMS
// Connection: WiFi Direct (TCP Socket)
// Uses Bonjour discovery + direct IP fallback
//
import Foundation
import Network
import UIKit

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
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    
    // Heartbeat to keep connection alive
    private var heartbeatTimer: Timer?
    private let heartbeatInterval: TimeInterval = 10.0 // Send heartbeat every 10 seconds
    
    // CRASH FIX: Store active connection as strong reference to prevent deallocation
    private var activeConnection: NWConnection?

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
        teardown()
    }

    // MARK: - Public API

    func disconnect() {
        teardown()
    }
    
    func sendCallAnswered() {
        sendPacket(["type": "CALL_ANSWERED"])
    }
    
    func sendCallRejected() {
        sendPacket(["type": "CALL_REJECTED"])
    }
    
    func sendCallEnded() {
        sendPacket(["type": "CALL_ENDED"])
    }
    
    func sendSMS(to number: String, body: String) {
        bridgeLogger.log("sendSMS called: to=\(number), body=\(body)", category: "SEND")
        sendPacket([
            "type": "SMS",
            "to": number,
            "body": body,
            "timestamp": Date().timeIntervalSince1970 * 1000
        ])
    }
    
    func sendAudioFrame(_ data: Data) {
        guard state == .connected, let conn = conn else {
            return
        }
        
        // Audio packet: [marker (1 byte)][length (4 bytes)][audio data]
        var packet = Data()
        packet.append(Self.MARK_AUDIO)
        
        var length = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &length, count: 4))
        packet.append(data)
        
        ioQ.async {
            conn.send(content: packet, completion: .contentProcessed { _ in })
        }
    }
    
    // MARK: - Send Packet (Private)

    private func sendPacket(_ json: [String: Any]) {
        let currentState = state
        let hasConnection = conn != nil
        bridgeLogger.log("sendPacket: state=\(currentState), hasConn=\(hasConnection)", category: "SEND")
        
        guard state == .connected, let conn = conn else {
            bridgeLogger.log("sendPacket: not connected, aborting", category: "SEND")
            return
        }
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: json)
            _ = String(data: jsonData, encoding: .utf8) // Verify UTF8
            
            // Binary protocol: [marker (1 byte)][length (4 bytes)][JSON data]
            var packet = Data()
            packet.append(Self.MARK_JSON)
            
            var length = UInt32(jsonData.count).bigEndian
            packet.append(Data(bytes: &length, count: 4))
            packet.append(jsonData)
            
            ioQ.async {
                conn.send(content: packet, completion: .contentProcessed { err in
                    if let err = err {
                        bridgeLogger.log("sendPacket error: \(err)", category: "SEND")
                    }
                })
            }
            
            bridgeLogger.log("sendPacket: \(json)", category: "SEND")
        } catch {
            bridgeLogger.log("sendPacket JSON error: \(error)", category: "SEND")
        }
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
        bridgeLogger.log(">>> startDiscovery() called", category: "BRIDGE")
        guard state == .idle || state == .searching else { return }

        updateStatus("Searching for Android...")
        state = .searching
        bridgeLogger.log(">>> state set to searching", category: "BRIDGE")

        browser?.cancel()
        browser = nil

        let params = NWParameters()
        params.includePeerToPeer = true

        bridgeLogger.log(">>> Creating browser", category: "BRIDGE")
        let browser = NWBrowser(for: .bonjour(type: Self.bonjourType, domain: nil), using: params)
        bridgeLogger.log(">>> Browser created", category: "BRIDGE")

        browser.stateUpdateHandler = { [weak self] newState in
            bridgeLogger.log(">>> Browser state: \(String(describing: newState))", category: "BRIDGE")
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
        bridgeLogger.log(">>> connectToIP() called: \(ip)", category: "BRIDGE")
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
        bridgeLogger.log(">>> connectToIP: calling connect()", category: "BRIDGE")
        connect(to: endpoint)
    }

    // MARK: - Connection

    private func connect(to endpoint: NWEndpoint) {
        bridgeLogger.log(">>> connect() called", category: "BRIDGE")
        guard state == .searching || state == .connecting || state == .idle else {
            bridgeLogger.log("Already connected, ignoring", category: "BRIDGE")
            return
        }

        updateStatus("Connecting...")
        state = .connecting
        bridgeLogger.log(">>> state set to connecting", category: "BRIDGE")

        let params = NWParameters.tcp
        params.prohibitExpensivePaths = false
        params.prohibitedInterfaceTypes = []

        let connection = NWConnection(to: endpoint, using: params)

        // ULTRA EARLY - log BEFORE setting handler
        bridgeLogger.log(">>> Created connection, setting state handler", category: "BRIDGE")
        
        connection.stateUpdateHandler = { [weak self] s in
            // ULTRA EARLY - first line of handler
            bridgeLogger.log(">>> stateUpdateHandler called: \(String(describing: s))", category: "BRIDGE")
            guard let self = self else { 
                bridgeLogger.log(">>> CRASH: self nil in state handler", category: "BRIDGE")
                return 
            }

            switch s {
            case .setup:
                bridgeLogger.log(">>> .setup", category: "BRIDGE")
                break

            case .preparing:
                bridgeLogger.log(">>> .preparing", category: "BRIDGE")
                break

            case .ready:
                // ULTRA EARLY LOG - before any async
                bridgeLogger.log("!!! .ready received", category: "BRIDGE")
                
                // CRASH FIX: Keep connection alive with strong reference
                self.activeConnection = connection
                bridgeLogger.log("!!! stored activeConnection", category: "BRIDGE")
                
                DispatchQueue.main.async { [weak self] in
                    bridgeLogger.log("!!! MAIN THREAD .ready", category: "BRIDGE")
                    guard let self = self else { 
                        bridgeLogger.log("CRASH: self nil", category: "BRIDGE")
                        return 
                    }
                    
                    if self.state != .connected {
                        bridgeLogger.log("Setting connected state", category: "BRIDGE")
                        self.state = .connected
                        self.isConnected = true
                        self.updateStatus("Connected!")
                        self.conn = self.activeConnection
                        
                        bridgeLogger.log("Starting readLoop", category: "BRIDGE")
                        self.readLoop(conn: self.activeConnection!)
                        
                        // Send HANDSHAKE - CRITICAL: Android expects this!
                        bridgeLogger.log("Sending HANDSHAKE...", category: "BRIDGE")
                        self.sendPacket([
                            "type": "HANDSHAKE", 
                            "platform": "ios", 
                            "version": "2.5"
                        ])
                        bridgeLogger.log("HANDSHAKE sent - waiting for response...", category: "BRIDGE")
                        
                        // Start heartbeat to keep connection alive
                        self.startHeartbeat()
                    }
                }

            case .failed(let err):
                bridgeLogger.log(">>> .failed: \(err.localizedDescription)", category: "BRIDGE")
                DispatchQueue.main.async {
                    self.updateError("Connection failed: \(err.localizedDescription)")
                    self.state = .idle
                    self.isConnected = false
                    self.scheduleReconnect()
                }

            case .waiting(let err):
                bridgeLogger.log(">>> .waiting: \(err.localizedDescription)", category: "BRIDGE")
                DispatchQueue.main.async {
                    self.updateStatus("Waiting for network...")
                }

            case .cancelled:
                bridgeLogger.log(">>> .cancelled", category: "BRIDGE")
                DispatchQueue.main.async {
                    self.updateStatus("Disconnected")
                    self.isConnected = false
                    self.state = .idle
                }

            @unknown default:
                bridgeLogger.log(">>> unknown state", category: "BRIDGE")
                break
            }
        }

        ioQ.async { [weak self] in
            bridgeLogger.log(">>> ioQ: about to start connection", category: "BRIDGE")
            self?.conn = connection
            self?.buf.removeAll()
            connection.start(queue: self?.ioQ ?? DispatchQueue.main)
            bridgeLogger.log(">>> ioQ: connection.start() called", category: "BRIDGE")
        }
        bridgeLogger.log(">>> connect() end - connection queued to start", category: "BRIDGE")
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
        bridgeLogger.log(">>> teardown called", category: "BRIDGE")
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        stopHeartbeat()
        
        // Store endpoint for reconnection
        let storedEndpoint = self.lastEndpoint
        
        activeConnection?.cancel()
        activeConnection = nil

        ioQ.async { [weak self] in
            self?.conn?.cancel()
            self?.conn = nil
            self?.buf.removeAll()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = false
            self.state = .idle
            
            // Auto-reconnect if we have an endpoint
            if let ep = storedEndpoint, self.reconnectAttempts < self.maxReconnectAttempts {
                self.reconnectAttempts += 1
                bridgeLogger.log(">>> Auto-reconnect attempt \(self.reconnectAttempts)/\(self.maxReconnectAttempts)", category: "BRIDGE")
                self.scheduleReconnect()
            } else if self.reconnectAttempts >= self.maxReconnectAttempts {
                bridgeLogger.log(">>> Max reconnect attempts reached", category: "BRIDGE")
                self.reconnectAttempts = 0 // Reset for next time
            }
        }
    }

    // MARK: - Heartbeat (Keep Connection Alive)

    private func startHeartbeat() {
        stopHeartbeat()
        bridgeLogger.log("Starting heartbeat (every \(heartbeatInterval)s)", category: "BRIDGE")
        
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            guard let self = self, self.state == .connected else { return }
            self.sendHeartbeat()
        }
    }
    
    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        bridgeLogger.log("Heartbeat stopped", category: "BRIDGE")
    }
    
    private func sendHeartbeat() {
        guard state == .connected else { return }
        
        bridgeLogger.log("Sending heartbeat PING", category: "BRIDGE")
        sendPacket(["type": "PING"])
    }

    // MARK: - Read Loop

    private func readLoop(conn: NWConnection) {
        bridgeLogger.log(">>> readLoop started", category: "BRIDGE")
        
        guard state == .connected else { 
            bridgeLogger.log(">>> readLoop: not connected, exit", category: "BRIDGE")
            return 
        }
        
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self = self else {
                bridgeLogger.log(">>> CRASH: self nil in receive", category: "BRIDGE")
                return
            }
            
            bridgeLogger.log(">>> receive callback", category: "BRIDGE")
            
            // Additional safety check - verify this connection is still the active one
            guard conn === self.conn else {
                bridgeLogger.log("Stale connection callback, ignoring", category: "BRIDGE")
                return
            }

            if let err = err {
                let code = (err as NSError).code
                // Ignore common disconnect codes (57 = socket closed, 54 = connection reset)
                // BUT error 53 (Software caused connection abort) means Android closed connection
                if code != 57 && code != 54 {
                    bridgeLogger.log("Receive error: \(code) - connection closed by remote", category: "BRIDGE")
                }
                DispatchQueue.main.async {
                    self.updateError("Connection lost")
                    self.teardown()
                }
                return
            }

            // Check if we received any data
            if let data = data, !data.isEmpty {
                bridgeLogger.log(">>> Received \(data.count) bytes of data", category: "BRIDGE")
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
            if conn === self.conn && self.state == .connected {
                bridgeLogger.log("Calling readLoop recursively...", category: "BRIDGE")
                self.readLoop(conn: conn)
            }
        }
    }

    // MARK: - Parse

    private func parse() {
        // Safety check - ensure we have enough data
        guard buf.count >= 1 else { 
            bridgeLogger.log("parse: not enough data (\(buf.count) bytes)", category: "PARSE")
            return 
        }

        // NEW: Check if this might be plain JSON (starts with {)
        // Some Android implementations send raw JSON without the binary header
        if buf.count >= 1 && buf[0] == 0x7B { // {
            bridgeLogger.log("Detected plain JSON (starts with {)", category: "PARSE")
            if let jsonString = String(data: buf, encoding: .utf8),
               jsonString.contains("{") {
                // Try to find the JSON start and parse
                if let startRange = jsonString.range(of: "{") {
                    let jsonStart = jsonString[startRange.lowerBound...]
                    bridgeLogger.log("Trying to parse as plain JSON: \(jsonStart.prefix(100))", category: "PARSE")
                    dispatchJSON(String(jsonStart))
                    buf.removeAll()
                }
                return
            }
        }

        // Guard against buffer overflow
        if buf.count > 10_000_000 {
            bridgeLogger.log("Buffer overflow, clearing", category: "PARSE")
            buf.removeAll()
            return
        }

        // Need at least 5 bytes for header
        guard buf.count >= 5 else { 
            bridgeLogger.log("parse: not enough data for header (\(buf.count) bytes)", category: "PARSE")
            return 
        }

        while buf.count >= 5 {
            let marker = buf[0]
            let len = (Int(buf[1]) << 24) | (Int(buf[2]) << 16) | (Int(buf[3]) << 8) | Int(buf[4])

            bridgeLogger.log("parse: marker=0x\(String(marker, radix: 16)), len=\(len), buf=\(buf.count)", category: "PARSE")

            // Validate length
            guard len > 0, len <= 1_000_000 else {
                bridgeLogger.log("Invalid packet length: \(len)", category: "PARSE")
                var found = false
                for i in 1..<min(buf.count, 100) {
                    if buf[i] == Self.MARK_JSON || buf[i] == Self.MARK_AUDIO || buf[i] == 0x7B {
                        bridgeLogger.log("Found potential JSON start at offset \(i)", category: "PARSE")
                        buf.removeFirst(i)
                        found = true
                        break
                    }
                }
                if !found { buf.removeAll() }
                return
            }

            // Check if we have complete packet
            guard buf.count >= 5 + len else { 
                bridgeLogger.log("Incomplete packet, need \(5+len), have \(buf.count)", category: "PARSE")
                break 
            }

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
        }
    }
    
    // MARK: - Dispatch JSON (Handle Incoming Packets)

    private func dispatchJSON(_ jsonString: String) {
        bridgeLogger.log("dispatchJSON: parsing \(jsonString.prefix(100))", category: "PARSE")
        
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            bridgeLogger.log("dispatchJSON: invalid JSON", category: "PARSE")
            return
        }
        
        bridgeLogger.log("dispatchJSON: type=\(type)", category: "PARSE")
        
        // Handle PONG from Android (response to our heartbeat)
        if type == "PONG" {
            bridgeLogger.log("Received PONG from Android - connection alive!", category: "BRIDGE")
            return
        }
        
        // Handle PING from Android
        if type == "PING" {
            bridgeLogger.log("Received PING from Android, responding with PONG", category: "BRIDGE")
            sendPacket(["type": "PONG"])
            return
        }
        
        // Handle HANDSHAKE response
        if type == "HANDSHAKE_ACK" {
            bridgeLogger.log("Received HANDSHAKE_ACK from Android!", category: "BRIDGE")
            return
        }
        
        // Handle incoming call
        if type == "CALL_INCOMING" {
            if let callId = json["callId"] as? String,
               let number = json["number"] as? String {
                let caller = json["caller"] as? String ?? ""
                bridgeLogger.log("dispatchJSON: CALL_INCOMING - \(caller) (\(number))", category: "CALL")
                
                let packet = CallPacket(callId: callId, caller: caller, number: number)
                DispatchQueue.main.async { [weak self] in
                    self?.onCallIncoming?(packet)
                }
            }
            return
        }
        
        // Handle call ended
        if type == "CALL_ENDED" {
            bridgeLogger.log("dispatchJSON: CALL_ENDED", category: "CALL")
            DispatchQueue.main.async { [weak self] in
                self?.onCallEnded?()
            }
            return
        }
        
        // Handle SMS
        if type == "SMS" {
            if let from = json["from"] as? String,
               let body = json["body"] as? String {
                let timestamp = json["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
                bridgeLogger.log("dispatchJSON: SMS from \(from)", category: "SMS")
                
                let packet = SMSPacket(sender: from, number: from, body: body, timestamp: timestamp, isHistory: false)
                DispatchQueue.main.async { [weak self] in
                    self?.onSMSReceived?(packet)
                }
            }
            return
        }
        
        bridgeLogger.log("dispatchJSON: unknown type \(type)", category: "PARSE")
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
