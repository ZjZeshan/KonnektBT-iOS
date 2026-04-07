# KonnektBT - iOS App Specification

## Overview

**KonnektBT** is an iPhone app that bridges calls and SMS from an Android phone to the iPhone over WiFi. The Android device acts as a server (with SIM card for calls/SMS), and the iPhone connects to it to receive and manage those calls and messages through the iPhone's native interfaces.

---

## Core Purpose

- **Call Bridging**: Receive incoming calls from Android SIM and manage them via iPhone's CallKit interface
- **SMS Forwarding**: Display Android SMS messages in iPhone app and allow replying
- **Audio Streaming**: Stream call audio bidirectionally between phones during active calls
- **Background Operation**: Maintain connection when iPhone is locked (VoIP background mode)

---

## Technical Architecture

### Connection Model
- **iPhone (Client)** → **Android (Server)** via TCP socket
- Port: `43210`
- Discovery: Bonjour/mDNS (`_konnekt._tcp`) OR direct IP input
- Both devices must be on same WiFi network

### Protocol Format
Each message has a 5-byte binary header + payload:
```
[1 byte marker][4 bytes length (big-endian)][payload]

Markers:
- 0xAC = JSON message
- 0xAB = Audio data (raw PCM)
```

### JSON Message Types

**iOS → Android:**
```json
{"type": "HANDSHAKE", "platform": "ios", "version": "2.8"}
{"type": "CALL_ANSWERED"}
{"type": "CALL_REJECTED"}
{"type": "CALL_ENDED"}
{"type": "SEND_SMS", "to": "+1234567890", "body": "Hello"}
{"type": "PONG"}
```

**Android → iOS:**
```json
{"type": "HANDSHAKE", "platform": "android"}
{"type": "HANDSHAKE_ACK"}
{"type": "CALL_INCOMING", "callId": "uuid", "caller": "John", "number": "+1234567890"}
{"type": "CALL_ENDED"}
{"type": "SMS_RECEIVED", "sender": "John", "number": "+1234567890", "body": "Hi", "timestamp": 1709136000000}
{"type": "SMS_HISTORY", "sender": "John", "number": "+1234567890", "body": "Hi", "timestamp": 1709136000000}
{"type": "HEARTBEAT"} or {"type": "PING"}
{"type": "PONG"}
```

### Audio Format
- Sample Rate: 16,000 Hz (16kHz)
- Bit Depth: 16-bit Linear PCM
- Channels: Mono
- Data: Raw Int16 samples (little-endian)

---

## User Interface

### Color Scheme
- Primary: `#00e5a0` (teal/green)
- Background: `#0a0c10` (near black)
- Cards: `#12151c` (dark gray)
- Error: `#ff4d6d` (red)
- Warning: Orange

### App Structure

**4 Tabs:**
1. **Home** - Connection status, active call card, feature cards
2. **Messages** - SMS inbox with thread view
3. **Pair** - Connection settings, manual IP entry
4. **Settings** - App info

### Tab 1: Home Screen

**Paired Status Banner (when connected):**
```
✅ PAIRED WITH ANDROID
Calls & SMS are being bridged
```
- Green background with border
- Checkmark icon

**Searching Banner (when disconnected):**
```
SEARCHING FOR ANDROID...
[status message]
[Retry Button]
```
- Orange background

**Active Call Card:**
- Shows when `isInCall == true`
- Caller name and number
- Timer (elapsed call time)
- "End Call" button (red)

**Feature Cards:**
- "📞 Calls - Forwarded to iPhone" with status dot
- "💬 SMS - [count] messages" with status dot

**Setup Guide (when disconnected):**
1. Install KONNEKT on Android
2. Connect both phones to same WiFi
3. Open KONNEKT on Android → tap Start
4. Go to Pair tab → Auto-Scan or enter IP

### Tab 2: Messages Screen

**Empty State:**
```
💬
No messages yet
SMS from Android will appear here
```

**Thread List:**
- Avatar circle with first 2 letters of sender name
- Sender name (bold)
- Message preview (gray, single line)
- Relative timestamp

**Thread View:**
- Messages sorted chronologically
- Incoming messages (from Android): Dark background, right-aligned
- Outgoing messages (from iPhone): Teal background, left-aligned
- Reply text field at bottom with send button

### Tab 3: Pair Screen

**Connection Status:**
- Green dot + "Connected ✓" OR orange dot + "Not Connected"
- Status text below

**Your iPhone IP Section:**
- Large IP address display (monospaced, teal)
- Copy to clipboard button
- Refresh button

**Auto-Scan Button:**
- Full-width teal button
- "🔍 Auto-Scan for Android"

**Manual IP Entry:**
- IP Address text field (decimal pad keyboard)
- Port text field (default: 43210)
- Connect button

**Hotspot Note:**
```
📱 MOBILE HOTSPOT?
1. Enable Personal Hotspot on iPhone
2. Connect Android to iPhone's hotspot
3. Use iPhone's hotspot IP above
4. Enter that IP in Android app
```

### Tab 4: Settings Screen

- App icon (phone with arrow)
- "KONNEKT" title
- "Android SIM → iPhone Bridge" subtitle
- Version: "2.0"

---

## Technical Implementation

### SwiftUI Views

```
ContentView (TabView)
├── HomeView
│   ├── pairedStatusBanner
│   ├── ActiveCallCard
│   └── FeatureCard (x2)
├── SMSInboxView
│   ├── SMSRowView
│   └── SMSThreadView
├── PairingView
└── SettingsView
```

### App State (ObservableObject)

```swift
class AppState: ObservableObject {
    let bridge: BluetoothBridge       // TCP connection manager
    let callKit: CallKitManager       // iOS call handling
    let audioManager: AudioStreamManager  // Audio capture/playback
    
    @Published var smsMessages: [SMSPacket]
    @Published var activeCall: CallPacket?
    @Published var isInCall: Bool
    @Published var isBridgeConnected: Bool
    @Published var bridgeStatus: String
    @Published var bridgeError: String?
}
```

### Data Models

```swift
struct CallPacket {
    let callId: String
    let caller: String  // Display name
    let number: String  // Phone number
}

struct SMSPacket: Identifiable {
    let id = UUID()
    let sender: String   // Contact name
    let number: String  // Phone number
    let body: String    // Message text
    let timestamp: TimeInterval
    let isHistory: Bool // true = from history sync, false = new
}
```

### Required iOS Frameworks
- SwiftUI
- CallKit
- AVFoundation / AVFAudio
- Network (NWBrowser, NWConnection, NWPathMonitor)

### Required Capabilities
- **Background Modes**: Audio, VoIP
- **Bonjour Services**: `_konnekt._tcp`
- **Local Network Usage** (Privacy description)

### Info.plist Entries
```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>voip</string>
</array>
<key>NSBonjourServices</key>
<array>
    <string>_konnekt._tcp</string>
</array>
<key>NSLocalNetworkUsageDescription</key>
<string>KonnektBT needs local network access to connect to your Android device.</string>
```

---

## Connection Flow

1. **App Launch:**
   - Initialize AppState
   - Start network path monitor
   - Begin Bonjour discovery after 1.5 seconds

2. **Discovery:**
   - Search for `_konnekt._tcp` service OR
   - User enters IP manually

3. **Connection:**
   - TCP connection to Android IP:43210
   - iOS sends HANDSHAKE
   - Android responds with HANDSHAKE + HANDSHAKE_ACK
   - Status changes to "Connected & Synced!"

4. **During Connection:**
   - Receive CALL_INCOMING → Show CallKit notification
   - Receive SMS_RECEIVED → Add to SMS inbox
   - Receive audio data → Play through speaker
   - Send audio from microphone → Stream to Android
   - Send/receive PING/PONG for keepalive

5. **Call Flow:**
   - CALL_INCOMING received → CallKit shows incoming call UI
   - User answers → `onCallAnswered` fires → Start audio engine → Send CALL_ANSWERED
   - User ends → Send CALL_ENDED → Stop audio engine

6. **Reconnection:**
   - If connection drops → Schedule reconnect in 5 seconds
   - Attempt to reconnect to last known endpoint
   - Or restart discovery

---

## File Structure

```
KonnektBT/
├── KonnektApp.swift           # @main App entry
├── Info.plist                 # Permissions, background modes
├── Bluetooth/
│   └── BluetoothBridge.swift   # TCP connection, packet parsing
├── Services/
│   ├── CallKitManager.swift   # CallKit integration
│   └── AudioStreamManager.swift # Audio engine, PCM streaming
├── Views/
│   └── ContentView.swift      # All SwiftUI views + AppState
└── Assets.xcassets/           # App icon, colors
```

---

## Edge Cases & Error Handling

1. **Duplicate Calls:** Ignore if callId matches lastCallId
2. **Duplicate SMS:** Check last 10 messages for number+body match
3. **Buffer Overflow:** Clear buffer if >10MB
4. **Invalid JSON:** Log and skip malformed packets
5. **Connection Lost:** Auto-reconnect with exponential backoff
6. **Audio Session Conflict:** Use voiceChat mode with Bluetooth HFP
7. **Background Audio:** Maintain audio session for VoIP
8. **Thread Safety:** Use DispatchQueue for shared state

---

## Dependencies

**None** - All functionality uses native iOS frameworks:
- SwiftUI (UI)
- Network (TCP/Bonjour)
- CallKit (Phone integration)
- AVFoundation (Audio)

---

## Build Requirements

- Xcode 15.0+
- iOS 16.0+ deployment target
- iPhone device or simulator
- Valid Apple Developer account (for device testing)
- Codemagic or local Xcode Cloud for CI/CD

---

## Testing Checklist

- [ ] App connects to Android on same WiFi
- [ ] HANDSHAKE exchange completes
- [ ] Incoming call shows CallKit notification
- [ ] Can answer/reject calls
- [ ] Audio streams during call
- [ ] SMS messages appear in inbox
- [ ] Can reply to SMS from app
- [ ] Connection survives iPhone lock
- [ ] Auto-reconnect after network loss
- [ ] No crashes on malformed data
