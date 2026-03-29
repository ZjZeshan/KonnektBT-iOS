// KonnektBT/Views/ContentView.swift
import SwiftUI
import Network

// ── AppState ──────────────────────────────────────────────────────────────────
class AppState: ObservableObject {
    let bridge       = BluetoothBridge()
    let callKit      = CallKitManager()
    let audioManager = AudioStreamManager()

    @Published var smsMessages: [SMSPacket] = []
    @Published var activeCall:  CallPacket?
    @Published var isInCall     = false

    // FIXED: Thread-safe state management
    private let stateQueue = DispatchQueue(label: "com.konnekt.appstate")

    init() {
        setupCallbacks()
        // Small delay so NWPathMonitor fires first and we don't double-connect
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.bridge.startDiscovery()
        }
    }

    func handleBackground() {
        print("[AppState] Background — keeping connection alive")
    }

    func handleForeground() {
        if !bridge.isConnected {
            print("[AppState] Foreground — reconnecting")
            bridge.startDiscovery()
        }
    }

    private func setupCallbacks() {
        // All bridge callbacks already arrive on main thread
        bridge.onCallIncoming = { [weak self] packet in
            guard let self = self else { return }
            // FIXED: Thread-safe state check
            self.stateQueue.sync {
                // Don't report if we already have this call active
                guard self.activeCall?.callId != packet.callId else { return }
            }

            DispatchQueue.main.async {
                self.activeCall = packet
                self.callKit.reportIncomingCall(
                    callId: packet.callId,
                    callerName: packet.caller.isEmpty ? "Unknown" : packet.caller,
                    callerNumber: packet.number)
            }
        }

        bridge.onCallEnded = { [weak self] in
            guard let self = self else { return }
            self.stateQueue.sync {
                self.isInCall = false
                self.activeCall = nil
            }
            self.callKit.endCall()
            self.audioManager.stop()
        }

        bridge.onSMSReceived = { [weak self] packet in
            guard let self = self else { return }
            DispatchQueue.main.async {
                // FIXED: Better dedup by checking last 5 messages only for performance
                let recentWindow = self.smsMessages.prefix(5)
                let isDupe = recentWindow.contains {
                    $0.number == packet.number &&
                    $0.body == packet.body &&
                    abs($0.timestamp - packet.timestamp) < 2000
                }
                guard !isDupe else { return }
                self.smsMessages.insert(packet, at: 0)
                // Limit history to 500 messages
                if self.smsMessages.count > 500 {
                    self.smsMessages = Array(self.smsMessages.prefix(500))
                }
            }
        }

        // Audio arrives on main thread — only play if we're actually in a call
        bridge.onAudioReceived = { [weak self] data in
            self?.stateQueue.sync {
                guard self?.isInCall == true else { return }
            }
            self?.audioManager.playAudio(data)
        }

        // FIXED: CallKit callbacks with proper cleanup
        var hasCallAnsweredCallback = false

        callKit.onCallAnswered = { [weak self] in
            guard let self = self else { return }
            self.stateQueue.sync { self.isInCall = true }

            // FIXED: Prevent multiple callbacks from registering multiple times
            guard !hasCallAnsweredCallback else { return }
            hasCallAnsweredCallback = true

            self.audioManager.start()
            self.bridge.sendCallAnswered()

            // FIXED: Store capture callback properly, remove on cleanup
            self.audioManager.onCapturedAudio = { [weak self] data in
                self?.bridge.sendAudioFrame(data)
            }
        }

        callKit.onCallRejected = { [weak self] in
            guard let self = self else { return }
            self.stateQueue.sync {
                self.isInCall = false
                self.activeCall = nil
            }
            self.bridge.sendCallRejected()
        }

        callKit.onCallEnded = { [weak self] in
            guard let self = self else { return }
            self.stateQueue.sync {
                self.isInCall = false
                self.activeCall = nil
            }
            self.bridge.sendCallEnded()
            self.audioManager.stop()
        }

        // FIXED: Handle send errors
        bridge.onSendError = { error in
            print("[Bridge] Send error: \(error)")
        }
    }

    // FIXED: Helper to check if in call (thread-safe)
    func checkIsInCall() -> Bool {
        var result = false
        stateQueue.sync { result = isInCall }
        return result
    }
}

// ── Tabs ──────────────────────────────────────────────────────────────────────
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home",     systemImage: "house.fill") }
            SMSInboxView()
                .tabItem { Label("Messages", systemImage: "message.fill") }
                .badge(appState.smsMessages.count)
            PairingView()
                .tabItem { Label("Pair",     systemImage: "link") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .tint(Color(hex: "#00e5a0"))
    }
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
                        connectionCard
                        if appState.isInCall, let call = appState.activeCall {
                            ActiveCallCard(call: call)
                        }
                        HStack(spacing: 12) {
                            FeatureCard(icon: "📞", title: "Calls",
                                        subtitle: "Forwarded to iPhone",
                                        active: appState.bridge.isConnected)
                            FeatureCard(icon: "💬", title: "SMS",
                                        subtitle: "\(appState.smsMessages.count) messages",
                                        active: appState.bridge.isConnected)
                        }
                        if !appState.bridge.isConnected { SetupGuideView() }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("KONNEKT")
        }
    }

    var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(appState.bridge.isConnected ? Color(hex: "#00e5a0") : Color.orange)
                    .frame(width: 10, height: 10)
                Text(appState.bridge.isConnected ? "ANDROID CONNECTED ✓" : "SEARCHING...")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(appState.bridge.isConnected ? Color(hex: "#00e5a0") : .orange)
            }
            if !appState.bridge.isConnected {
                Button("Retry Connection") { appState.bridge.startDiscovery() }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(Color(hex: "#00e5a0"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(hex: "#12151c"))
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20)
            .stroke(appState.bridge.isConnected
                    ? Color(hex: "#00e5a0").opacity(0.3)
                    : Color.orange.opacity(0.3), lineWidth: 1))
    }
}

// ── Active Call ───────────────────────────────────────────────────────────────
struct ActiveCallCard: View {
    let call: CallPacket
    @EnvironmentObject var appState: AppState
    @State private var elapsed = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // FIXED: Reset timer when call ends
    private func resetTimer() {
        elapsed = 0
    }

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
        .onDisappear { resetTimer() }
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
            Circle().fill(active ? Color(hex: "#00e5a0") : .gray).frame(width: 8, height: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color(hex: "#12151c")).cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: "#22273a"), lineWidth: 1))
    }
}

struct SetupGuideView: View {
    let steps = ["1. Install KONNEKT on Android",
                 "2. Connect both phones to same WiFi",
                 "3. Open KONNEKT on Android → tap Start",
                 "4. Tap Pair tab below"]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SETUP GUIDE").font(.system(.caption, design: .monospaced)).foregroundColor(.gray)
            ForEach(steps, id: \.self) { Text($0).font(.system(.caption)).foregroundColor(.gray) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Color(hex: "#12151c")).cornerRadius(16)
    }
}

// ── SMS Inbox ─────────────────────────────────────────────────────────────────
struct SMSInboxView: View {
    @EnvironmentObject var appState: AppState

    // FIXED: Memoize threads to prevent recalculation on every render
    @State private var cachedThreads: [[SMSPacket]] = []

    var threads: [[SMSPacket]] {
        let grouped = Dictionary(grouping: appState.smsMessages, by: { $0.number })
        let result = grouped.values
            .map { $0.sorted { $0.timestamp > $1.timestamp } }
            .sorted { ($0.first?.timestamp ?? 0) > ($1.first?.timestamp ?? 0) }
        return result
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
                    List(threads, id: \.first?.id) { thread in
                        if let latest = thread.first {
                            NavigationLink(destination: SMSThreadView(
                                number: latest.number, messages: thread)) {
                                SMSRowView(packet: latest)
                            }
                            .listRowBackground(Color(hex: "#12151c"))
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
    @State private var messageCount = 0

    var sorted: [SMSPacket] { messages.sorted { $0.timestamp < $1.timestamp } }

    // FIXED: Track last message ID for auto-scroll
    @State private var lastMessageId: UUID?

    var body: some View {
        ZStack {
            Color(hex: "#0a0c10").ignoresSafeArea()
            VStack {
                ScrollViewReader { proxy in
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
                                .padding(.horizontal).id(msg.id)
                            }
                        }.padding(.vertical)
                    }
                    // FIXED: Proper scroll-to-bottom on new messages
                    .onChange(of: sorted.count) { newCount in
                        if newCount > messageCount, let last = sorted.last {
                            withAnimation(.easeOut(duration: 0.3)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                        messageCount = newCount
                        lastMessageId = sorted.last?.id
                    }
                }
                HStack(spacing: 10) {
                    TextField("Reply...", text: $replyText)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color(hex: "#12151c")).cornerRadius(20).foregroundColor(.white)
                    Button {
                        guard !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        appState.bridge.sendSMS(to: number, body: replyText.trimmingCharacters(in: .whitespacesAndNewlines))
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
        .onAppear {
            messageCount = sorted.count
            lastMessageId = sorted.last?.id
        }
    }
}

// ── Pairing ───────────────────────────────────────────────────────────────────
struct PairingView: View {
    @EnvironmentObject var appState: AppState
    @State private var ipAddress = ""
    @State private var status = "Tap Scan or enter Android IP manually"
    @State private var showInvalidIPAlert = false

    // FIXED: IP validation pattern
    private var isValidIP: Bool {
        let parts = ipAddress.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let num = Int(part) else { return false }
            return num >= 0 && num <= 255
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#0a0c10").ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {

                        // ── Connection status ──────────────────────────────
                        HStack(spacing: 10) {
                            Circle()
                                .fill(appState.bridge.isConnected ? Color(hex: "#00e5a0") : Color.orange)
                                .frame(width: 10, height: 10)
                            Text(appState.bridge.isConnected ? "Android Connected ✓" : "Not Connected")
                                .foregroundColor(.white).font(.subheadline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(hex: "#12151c")).cornerRadius(14)

                        // ── iPhone's own IP (for typing into Android app) ──
                        VStack(alignment: .leading, spacing: 8) {
                            Text("THIS IPHONE'S IP ADDRESS")
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
                            Text("Type this IP into your Android KONNEKT app")
                                .font(.caption2)
                                .foregroundColor(Color(hex: "#6b7280"))
                            Button {
                                appState.bridge.refreshLocalIP()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.clockwise")
                                    Text("Refresh IP")
                                }
                                .font(.caption)
                                .foregroundColor(Color(hex: "#00e5a0"))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(hex: "#0a1f16"))
                        .cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(Color(hex: "#00e5a0").opacity(0.3), lineWidth: 1))

                        // ── Auto scan ──────────────────────────────────────
                        Button {
                            status = "Scanning for Android device..."
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

                        // ── Manual IP (connect iPhone → Android) ───────────
                        VStack(alignment: .leading, spacing: 10) {
                            Text("CONNECT TO ANDROID IP")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(Color(hex: "#6b7280"))
                            Text("Use this if Android app shows its IP")
                                .font(.caption2).foregroundColor(.gray)
                            TextField("192.168.x.x", text: $ipAddress)
                                .keyboardType(.decimalPad).padding(14)
                                .background(Color(hex: "#12151c")).cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(isValidIP || ipAddress.isEmpty ? Color(hex: "#22273a") : Color.red, lineWidth: 1))
                                .foregroundColor(.white)

                            // FIXED: Show validation error
                            if !ipAddress.isEmpty && !isValidIP {
                                Text("Invalid IP format (e.g., 192.168.1.100)")
                                    .font(.caption2).foregroundColor(.red)
                            }

                            Button {
                                guard !ipAddress.isEmpty else { return }
                                guard isValidIP else {
                                    showInvalidIPAlert = true
                                    return
                                }
                                appState.bridge.connectToIP(ipAddress)
                                status = "Connecting to \(ipAddress)..."
                            } label: {
                                Text("Connect to Android")
                                    .foregroundColor(.white).frame(maxWidth: .infinity).padding()
                                    .background(Color(hex: "#12151c")).cornerRadius(14)
                                    .overlay(RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color(hex: "#22273a"), lineWidth: 1))
                            }
                            .disabled(ipAddress.isEmpty)
                            .opacity(ipAddress.isEmpty ? 0.5 : 1.0)
                        }

                        Text(status)
                            .font(.caption).foregroundColor(.gray)
                            .multilineTextAlignment(.center)

                        // ── Hotspot note ───────────────────────────────────
                        VStack(alignment: .leading, spacing: 6) {
                            Text("📱 USING MOBILE HOTSPOT?")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.orange)
                            Text("If you're sharing iPhone's connection:\n1. Enable Personal Hotspot on iPhone\n2. Connect Android to iPhone's hotspot\n3. Your IP above will show the hotspot address\n4. Type that IP into Android KONNEKT app")
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
            .alert("Invalid IP Address", isPresented: $showInvalidIPAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Please enter a valid IP address (e.g., 192.168.1.100)")
            }
        }
    }
}

// ── Settings ──────────────────────────────────────────────────────────────────
struct SettingsView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#0a0c10").ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "phone.arrow.up.right.fill")
                        .font(.system(size: 60)).foregroundColor(Color(hex: "#00e5a0"))
                    Text("KONNEKT").font(.system(size: 28, weight: .bold)).foregroundColor(.white)
                    Text("Android SIM → iPhone Bridge")
                        .font(.system(.caption, design: .monospaced)).foregroundColor(.gray)
                    Text("Version 1.0 (Fixed)")
                        .font(.caption2).foregroundColor(Color(hex: "#6b7280"))
                }
            }
            .navigationTitle("Settings")
        }
    }
}

// ── Color Helper ──────────────────────────────────────────────────────────────
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        self.init(red: Double((int>>16)&0xFF)/255,
                  green: Double((int>>8)&0xFF)/255,
                  blue: Double(int&0xFF)/255)
    }
}
