// KonnektBT/Views/ContentView.swift
import SwiftUI
import AVFoundation
import UIKit

// Global logger instance
let logger = Logger.shared

// ── AppState ──────────────────────────────────────────────────────────────────
class AppState: ObservableObject {
    let bridge       = BluetoothBridge()
    let callKit      = CallKitManager()
    let audioManager = AudioStreamManager()

    @Published var smsMessages: [SMSPacket] = []
    @Published var activeCall:  CallPacket?
    @Published var isInCall     = false
    
    // Mirror bridge state so SwiftUI can observe it
    @Published var isBridgeConnected: Bool = false
    @Published var bridgeStatus: String = "Ready"
    @Published var bridgeError: String?
    
    // Timer for bridge observation - stored as property for cleanup
    private var bridgeObserverTimer: Timer?

    init() {
        logger.log("AppState INIT - starting setup", category: "APP")
        setupBridgeObserver()
        logger.log("AppState setupBridgeObserver done", category: "APP")
        setupCallbacks()
        logger.log("AppState setupCallbacks done", category: "APP")
        // Start discovery after network monitor initializes
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            logger.log("Starting discovery...", category: "APP")
            self?.bridge.startDiscovery()
        }
        logger.log("AppState INIT complete", category: "APP")
    }
    
    deinit {
        // Clean up timer when AppState is deallocated
        bridgeObserverTimer?.invalidate()
        logger.log("AppState DEINIT - cleanup complete", category: "APP")
    }
    
    private func setupBridgeObserver() {
        logger.log("Creating bridge observer timer", category: "APP")
        // Observe bridge changes manually
        // Using Timer stored as property to allow proper cleanup
        bridgeObserverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else {
                logger.log("Timer fired but self is nil, invalidating", category: "APP")
                timer.invalidate()
                return
            }
            // CRASH SAFETY: All bridge property access must be on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Safely update published properties
                let newConnected = self.bridge.isConnected
                let newStatus = self.bridge.connectionStatus
                let newError = self.bridge.lastError
                
                if self.isBridgeConnected != newConnected || self.bridgeStatus != newStatus {
                    logger.log("Bridge state changed: connected=\(newConnected), status=\(newStatus)", category: "APP")
                }
                
                self.isBridgeConnected = newConnected
                self.bridgeStatus = newStatus
                self.bridgeError = newError
            }
        }
    }

    func handleBackground() {
        logger.log("Entering background", category: "APP")
        // Keep audio session active for VoIP background mode
        activateBackgroundAudio()
    }
    
    func handleForeground() {
        logger.log("Entering foreground", category: "APP")
        // Reconnect if needed
        if !bridge.isConnected {
            bridge.startDiscovery()
        }
    }
    
    private func activateBackgroundAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("Audio session error: \(error)")
        }
    }

    private func setupCallbacks() {
        logger.log("Setting up callbacks", category: "APP")
        
        // Connection errors
        bridge.onConnectionError = { [weak self] error in
            logger.log("Connection error callback: \(error)", category: "APP")
            DispatchQueue.main.async {
                self?.bridgeError = error
            }
        }

        // Incoming call - CRASH SAFE
        bridge.onCallIncoming = { [weak self] packet in
            logger.log("onCallIncoming: callId=\(packet.callId), caller=\(packet.caller)", category: "APP")
            DispatchQueue.main.async {
                guard let self = self else {
                    logger.log("onCallIncoming: self is nil!", category: "APP")
                    return
                }
                // Guard against duplicate calls
                if self.activeCall?.callId == packet.callId {
                    logger.log("Duplicate call ignored", category: "APP")
                    return
                }
                self.activeCall = packet
                
                let callerName = packet.caller.isEmpty ? "Unknown" : packet.caller
                logger.log("Reporting incoming call to CallKit", category: "APP")
                self.callKit.reportIncomingCall(
                    callId: packet.callId,
                    callerName: callerName,
                    callerNumber: packet.number)
                logger.log("reportIncomingCall completed", category: "APP")
            }
        }

        // Call ended - CRASH SAFE
        bridge.onCallEnded = { [weak self] in
            logger.log("onCallEnded callback", category: "APP")
            DispatchQueue.main.async {
                guard let self = self else { return }
                logger.log("Ending call in CallKit", category: "APP")
                self.callKit.endCall()
                self.audioManager.stop()
                self.activeCall = nil
                self.isInCall = false
                logger.log("Call ended cleanup done", category: "APP")
            }
        }

        // SMS received - CRASH SAFE
        bridge.onSMSReceived = { [weak self] packet in
            logger.log("onSMSReceived: from=\(packet.sender)", category: "APP")
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Simple dedup - check last 10 messages
                let isDupe = self.smsMessages.prefix(10).contains {
                    $0.number == packet.number && $0.body == packet.body
                }
                guard !isDupe else { return }
                
                self.smsMessages.insert(packet, at: 0)
                if self.smsMessages.count > 500 {
                    self.smsMessages = Array(self.smsMessages.prefix(500))
                }
                logger.log("SMS added, total: \(self.smsMessages.count)", category: "APP")
            }
        }

        // Audio playback during call - CRASH SAFE
        bridge.onAudioReceived = { [weak self] data in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.isInCall else { return }
                self.audioManager.playAudio(data)
            }
        }

        // Call answered by user - CRASH SAFE
        callKit.onCallAnswered = { [weak self] in
            logger.log("onCallAnswered callback", category: "APP")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isInCall = true
                logger.log("Starting audio manager", category: "APP")
                self.audioManager.start()
                self.bridge.sendCallAnswered()
                self.audioManager.onCapturedAudio = { [weak self] data in
                    self?.bridge.sendAudioFrame(data)
                }
                logger.log("Call answered setup complete", category: "APP")
            }
        }

        // Call rejected - CRASH SAFE
        callKit.onCallRejected = { [weak self] in
            logger.log("onCallRejected callback", category: "APP")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.bridge.sendCallRejected()
                self.activeCall = nil
                self.isInCall = false
            }
        }

        // Call ended from UI - CRASH SAFE
        callKit.onCallEnded = { [weak self] in
            logger.log("onCallEnded (UI) callback", category: "APP")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.bridge.sendCallEnded()
                self.audioManager.stop()
                self.activeCall = nil
                self.isInCall = false
            }
        }
        
        logger.log("All callbacks set up", category: "APP")
    }
}

// ── Tabs ──────────────────────────────────────────────────────────────────────
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    // Safe message count to avoid crashes during updates
    private var messageCount: Int {
        appState.smsMessages.count
    }
    
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
            SMSInboxView()
                .tabItem { Label("Messages", systemImage: "message.fill") }
                .badge(messageCount)
            PairingView()
                .tabItem { Label("Pair", systemImage: "link") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .tint(Color(hex: "#00e5a0"))
        .onChange(of: selectedTab) { _ in
            // Haptic feedback on tab change
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
    }
    
    @State private var selectedTab = 0
}

// ── Home ──────────────────────────────────────────────────────────────────────
struct HomeView: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#0a0c10").ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        // ── PAIRED STATUS BANNER ──────────────────────────
                        pairedStatusBanner
                        
                        if appState.isInCall, let call = appState.activeCall {
                            ActiveCallCard(call: call)
                        }
                        
                        HStack(spacing: 12) {
                            FeatureCard(icon: "📞", title: "Calls",
                                        subtitle: "Forwarded to iPhone",
                                        active: appState.isBridgeConnected)
                            FeatureCard(icon: "💬", title: "SMS",
                                        subtitle: "\(appState.smsMessages.count) messages",
                                        active: appState.isBridgeConnected)
                        }
                        
                        if !appState.isBridgeConnected {
                            SetupGuideView()
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("KONNEKT")
        }
    }

    // ── PAIRED STATUS BANNER ──────────────────────────────────────────────
    var pairedStatusBanner: some View {
        VStack(spacing: 16) {
            if appState.isBridgeConnected {
                // ✅ PAIRED STATE
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(Color(hex: "#00e5a0"))
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("✅ PAIRED WITH ANDROID")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color(hex: "#00e5a0"))
                        Text("Calls & SMS are being bridged")
                            .font(.system(.caption))
                            .foregroundColor(.gray)
                    }
                    
                    Spacer()
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(hex: "#00e5a0").opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(hex: "#00e5a0").opacity(0.5), lineWidth: 2)
                )
            } else {
                // 🔍 NOT PAIRED STATE
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 44))
                        .foregroundColor(.orange)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SEARCHING FOR ANDROID...")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.orange)
                        Text(appState.bridgeStatus)
                            .font(.system(.caption))
                            .foregroundColor(.gray)
                    }
                    
                    Spacer()
                    
                    Button {
                        appState.bridge.startDiscovery()
                    } label: {
                        Text("Retry")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.orange)
                            .cornerRadius(20)
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.orange.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.orange.opacity(0.5), lineWidth: 2)
                )
                
                // Error message if any
                if let error = appState.bridgeError {
                    Text("⚠️ \(error)")
                        .font(.system(.caption))
                        .foregroundColor(.red)
                        .padding(.horizontal, 16)
                }
            }
        }
    }
}

// ── Active Call ───────────────────────────────────────────────────────────────
struct ActiveCallCard: View {
    let call: CallPacket
    @EnvironmentObject var appState: AppState
    @State private var elapsed = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            Text("● ACTIVE CALL").font(.system(.caption, design: .monospaced))
                .foregroundColor(Color(hex: "#00e5a0"))
            Text(call.caller).font(.system(size: 22, weight: .bold)).foregroundColor(.white)
            Text(call.number).font(.system(.caption, design: .monospaced)).foregroundColor(.gray)
            Text(formatTime(elapsed)).font(.system(.title3, design: .monospaced))
                .foregroundColor(Color(hex: "#00e5a0"))
            Button("End Call") { appState.callKit.endCallFromApp() }
                .foregroundColor(.white)
                .padding(.horizontal, 28).padding(.vertical, 10)
                .background(Color(hex: "#ff4d6d")).cornerRadius(22)
        }
        .frame(maxWidth: .infinity).padding(20)
        .background(Color(hex: "#0a1f16")).cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20)
            .stroke(Color(hex: "#00e5a0").opacity(0.3), lineWidth: 1))
        .onReceive(timer) { _ in elapsed += 1 }
    }

    func formatTime(_ s: Int) -> String {
        String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// ── Feature + Setup ───────────────────────────────────────────────────────────
struct FeatureCard: View {
    let icon: String; let title: String; let subtitle: String; let active: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(icon).font(.title2)
            Text(title).font(.system(size: 14, weight: .bold)).foregroundColor(.white)
            Text(subtitle).font(.system(.caption2, design: .monospaced)).foregroundColor(.gray)
            // Safe Circle with ternary operator
            Circle()
                .fill(active ? Color(hex: "#00e5a0") : Color.gray)
                .frame(width: 8, height: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color(hex: "#12151c")).cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: "#22273a"), lineWidth: 1))
    }
}

struct SetupGuideView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SETUP GUIDE").font(.system(.caption, design: .monospaced)).foregroundColor(.gray)
            Text("1. Install KONNEKT on Android")
                .font(.system(.caption)).foregroundColor(.gray)
            Text("2. Connect both phones to same WiFi")
                .font(.system(.caption)).foregroundColor(.gray)
            Text("3. Open KONNEKT on Android → tap Start")
                .font(.system(.caption)).foregroundColor(.gray)
            Text("4. Go to Pair tab → Auto-Scan or enter IP")
                .font(.system(.caption)).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color(hex: "#12151c")).cornerRadius(16)
    }
}

// ── SMS Inbox ─────────────────────────────────────────────────────────────────
struct SMSInboxView: View {
    @EnvironmentObject var appState: AppState

    // Safe computed property for threads
    var threads: [[SMSPacket]] {
        // Take a snapshot to avoid concurrent modification
        let messages = appState.smsMessages
        guard !messages.isEmpty else { return [] }
        
        let grouped = Dictionary(grouping: messages, by: { $0.number })
        let sortedThreads = grouped.values
            .map { $0.sorted { $0.timestamp > $1.timestamp } }
            .sorted { ($0.first?.timestamp ?? 0) > ($1.first?.timestamp ?? 0) }
        
        // Filter out any empty threads as a safety measure
        return sortedThreads.filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#0a0c10").ignoresSafeArea()
                if appState.smsMessages.isEmpty {
                    VStack(spacing: 12) {
                        Text("💬").font(.largeTitle)
                        Text("No messages yet").foregroundColor(.gray)
                        Text("SMS from Android will appear here")
                            .font(.caption).foregroundColor(Color(hex: "#6b7280"))
                    }
                } else {
                    // Use safe ForEach with indices
                    List {
                        ForEach(threads.indices, id: \.self) { index in
                            let thread = threads[index]
                            if let latest = thread.first {
                                NavigationLink(destination: SMSThreadView(
                                    number: latest.number, messages: thread)) {
                                    SMSRowView(packet: latest)
                                }
                                .listRowBackground(Color(hex: "#12151c"))
                            }
                        }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Messages")
        }
    }
}

struct SMSRowView: View {
    let packet: SMSPacket
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#0d3d2c")).frame(width: 44, height: 44)
                Text(String(packet.sender.prefix(2)).uppercased())
                    .font(.system(size: 15, weight: .bold)).foregroundColor(Color(hex: "#00e5a0"))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(packet.sender).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                Text(packet.body).font(.caption).foregroundColor(.gray).lineLimit(1)
            }
            Spacer()
            Text(packet.date, style: .relative)
                .font(.system(.caption2, design: .monospaced)).foregroundColor(.gray)
        }
        .padding(.vertical, 6)
    }
}

struct SMSThreadView: View {
    let number: String
    let messages: [SMSPacket]
    @EnvironmentObject var appState: AppState
    @State private var replyText = ""

    var sorted: [SMSPacket] { messages.sorted { $0.timestamp < $1.timestamp } }

    var body: some View {
        ZStack {
            Color(hex: "#0a0c10").ignoresSafeArea()
            VStack {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(sorted) { msg in
                            HStack {
                                if msg.isHistory { Spacer(minLength: 40) }
                                Text(msg.body)
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(msg.isHistory ? Color(hex: "#00e5a0") : Color(hex: "#1a1e28"))
                                    .foregroundColor(msg.isHistory ? Color(hex: "#001a0d") : .white)
                                    .cornerRadius(16)
                                if !msg.isHistory { Spacer(minLength: 40) }
                            }
                            .padding(.horizontal)
                        }
                    }.padding(.vertical)
                }
                HStack(spacing: 10) {
                    TextField("Reply...", text: $replyText)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color(hex: "#12151c")).cornerRadius(20).foregroundColor(.white)
                    Button {
                        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        appState.bridge.sendSMS(to: number, body: text)
                        replyText = ""
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2).foregroundColor(Color(hex: "#00e5a0"))
                    }
                }.padding()
            }
        }
        .navigationTitle(messages.first?.sender ?? number)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// ── Pairing ───────────────────────────────────────────────────────────────────
struct PairingView: View {
    @EnvironmentObject var appState: AppState
    @State private var ipAddress = ""
    @State private var port = "43210"
    @State private var showError = false
    @State private var errorMessage = ""

    var isValidIP: Bool {
        let parts = ipAddress.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let num = Int(part), num >= 0, num <= 255 else { return false }
            return true
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#0a0c10").ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {

                        // ── Connection Status ──────────────────────────────
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle()
                                    .fill(appState.bridge.isConnected ? Color(hex: "#00e5a0") : Color.orange)
                                    .frame(width: 10, height: 10)
                                Text(appState.bridge.isConnected ? "Connected ✓" : "Not Connected")
                                    .foregroundColor(.white)
                            }
                            Text(appState.bridge.connectionStatus)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.gray)
                            if let error = appState.bridge.lastError {
                                Text(error)
                                    .font(.system(.caption2))
                                    .foregroundColor(.red)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(hex: "#12151c")).cornerRadius(14)

                        // ── iPhone IP ─────────────────────────────────────
                        VStack(alignment: .leading, spacing: 8) {
                            Text("YOUR iPHONE IP")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(Color(hex: "#6b7280"))
                            HStack {
                                Text(appState.bridge.localIPAddress)
                                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(hex: "#00e5a0"))
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = appState.bridge.localIPAddress
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .foregroundColor(Color(hex: "#00e5a0"))
                                }
                            }
                            Text("Tell Android app this IP")
                                .font(.caption2).foregroundColor(Color(hex: "#6b7280"))
                            Button {
                                appState.bridge.refreshLocalIP()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.clockwise")
                                    Text("Refresh")
                                }
                                .font(.caption).foregroundColor(Color(hex: "#00e5a0"))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(hex: "#0a1f16"))
                        .cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(Color(hex: "#00e5a0").opacity(0.3), lineWidth: 1))

                        // ── Auto Scan ─────────────────────────────────────
                        Button {
                            appState.bridge.startDiscovery()
                        } label: {
                            HStack {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                Text("Auto-Scan for Android")
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(Color(hex: "#001a0d"))
                            .frame(maxWidth: .infinity).padding()
                            .background(Color(hex: "#00e5a0")).cornerRadius(14)
                        }

                        Divider().background(Color(hex: "#22273a"))

                        // ── Manual IP ────────────────────────────────────
                        VStack(alignment: .leading, spacing: 10) {
                            Text("CONNECT BY IP")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(Color(hex: "#6b7280"))

                            TextField("IP Address (e.g., 192.168.1.100)", text: $ipAddress)
                                .keyboardType(.decimalPad)
                                .padding(14)
                                .background(Color(hex: "#12151c")).cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(ipAddress.isEmpty || isValidIP ? Color(hex: "#22273a") : Color.red, lineWidth: 1))
                                .foregroundColor(.white)

                            TextField("Port (default: 43210)", text: $port)
                                .keyboardType(.numberPad)
                                .padding(14)
                                .background(Color(hex: "#12151c")).cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color(hex: "#22273a"), lineWidth: 1))
                                .foregroundColor(.white)

                            Button {
                                guard !ipAddress.isEmpty else { return }
                                guard isValidIP else {
                                    errorMessage = "Invalid IP address"
                                    showError = true
                                    return
                                }
                                let p = UInt16(port) ?? 43210
                                appState.bridge.connectToIP(ipAddress, port: p)
                            } label: {
                                Text("Connect")
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity).padding()
                                    .background(Color(hex: "#12151c")).cornerRadius(14)
                                    .overlay(RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color(hex: "#22273a"), lineWidth: 1))
                            }
                            .disabled(ipAddress.isEmpty)
                            .opacity(ipAddress.isEmpty ? 0.5 : 1.0)
                        }

                        // ── Hotspot Note ─────────────────────────────────
                        VStack(alignment: .leading, spacing: 6) {
                            Text("📱 MOBILE HOTSPOT?")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.orange)
                            Text("1. Enable Personal Hotspot on iPhone\n2. Connect Android to iPhone's hotspot\n3. Use iPhone's hotspot IP above\n4. Enter that IP in Android app")
                                .font(.caption2).foregroundColor(.gray)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(hex: "#1a1200"))
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1))

                        Spacer()
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Pair Devices")
            .onAppear { appState.bridge.refreshLocalIP() }
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
    }
}

// ── Settings ──────────────────────────────────────────────────────────────────
struct SettingsView: View {
    @State private var showLogViewer = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#0a0c10").ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        Image(systemName: "phone.arrow.up.right.fill")
                            .font(.system(size: 60)).foregroundColor(Color(hex: "#00e5a0"))
                        Text("KONNEKT").font(.system(size: 28, weight: .bold)).foregroundColor(.white)
                        Text("Android SIM → iPhone Bridge")
                            .font(.system(.caption, design: .monospaced)).foregroundColor(.gray)
                        Text("Version 2.0")
                            .font(.caption2).foregroundColor(Color(hex: "#6b7280"))
                        
                        // Debug Section
                        Divider().background(Color(hex: "#22273a"))
                        
                        VStack(spacing: 12) {
                            Text("DEBUG TOOLS")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.gray)
                            
                            Button {
                                showLogViewer = true
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text.magnifyingglass")
                                    Text("View Crash Logs")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .foregroundColor(Color(hex: "#00e5a0"))
                                .padding()
                                .background(Color(hex: "#12151c"))
                                .cornerRadius(12)
                            }
                            
                            Button {
                                let logPath = logger.getLogFileURL()
                                let activityVC = UIActivityViewController(
                                    activityItems: [logPath],
                                    applicationActivities: nil
                                )
                                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                   let rootVC = windowScene.windows.first?.rootViewController {
                                    rootVC.present(activityVC, animated: true)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Share Logs")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .foregroundColor(Color(hex: "#00e5a0"))
                                .padding()
                                .background(Color(hex: "#12151c"))
                                .cornerRadius(12)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 40)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showLogViewer) {
                LogViewerView()
            }
        }
    }
}

// ── Log Viewer ─────────────────────────────────────────────────────────────────
struct LogViewerView: View {
    @State private var logContent = ""
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#0a0c10").ignoresSafeArea()
                VStack {
                    if logContent.isEmpty {
                        Text("No logs yet")
                            .foregroundColor(.gray)
                    } else {
                        ScrollView {
                            Text(logContent)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color(hex: "#00e5a0"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                    }
                }
            }
            .navigationTitle("Crash Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color(hex: "#00e5a0"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        let logPath = logger.getLogFileURL()
                        let activityVC = UIActivityViewController(
                            activityItems: [logPath],
                            applicationActivities: nil
                        )
                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let rootVC = windowScene.windows.first?.rootViewController {
                            rootVC.present(activityVC, animated: true)
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(Color(hex: "#00e5a0"))
                    }
                }
            }
            .onAppear {
                logContent = logger.getLogContents()
            }
        }
    }
}

// ── Color Helper ──────────────────────────────────────────────────────────────
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        // Safely handle invalid hex strings
        guard Scanner(string: hex).scanHexInt64(&int) else {
            // Default to dark gray if invalid
            self.init(red: 0.1, green: 0.1, blue: 0.1)
            return
        }
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
