// KonnektBT/Services/CallKitManager.swift
import Foundation
import CallKit
import AVFAudio

// File-based logger
let callKitLogger = Logger.shared

class CallKitManager: NSObject, ObservableObject {

    private let provider:        CXProvider
    private let callController = CXCallController()

    var onCallAnswered: (() -> Void)?
    var onCallEnded:    (() -> Void)?
    var onCallRejected: (() -> Void)?

    private var activeCallUUID:  UUID?
    private var callWasAnswered  = false   // track so we know answered vs rejected on end

    // FIXED: Thread-safe state management
    private let stateQueue = DispatchQueue(label: "com.konnekt.callkit.state")
    private var audioSessionConfigured = false

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo          = false
        config.maximumCallGroups      = 1
        config.supportedHandleTypes   = [.phoneNumber]
        config.includesCallsInRecents = true
        config.iconTemplateImageData   = nil // Set app icon if needed

        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    // Called by bridge when Android reports an incoming call
    func reportIncomingCall(callId: String, callerName: String, callerNumber: String) {
        callKitLogger.log("reportIncomingCall: callId=\(callId), callerName=\(callerName), number=\(callerNumber)", category: "CALLKIT")
        
        // FIXED: Thread-safe state check
        var hasActiveCall = false
        stateQueue.sync { hasActiveCall = activeCallUUID != nil }
        callKitLogger.log("Has active call: \(hasActiveCall)", category: "CALLKIT")

        // If a call is already active, end it first before reporting new one
        if hasActiveCall, let existing = stateQueue.sync(execute: { activeCallUUID }) {
            callKitLogger.log("Ending existing call first", category: "CALLKIT")
            provider.reportCall(with: existing, endedAt: Date(), reason: .remoteEnded)
            stateQueue.sync { self.activeCallUUID = nil }
        }

        let uuid = UUID()
        callKitLogger.log("Creating new call UUID: \(uuid)", category: "CALLKIT")
        stateQueue.sync {
            self.activeCallUUID   = uuid
            self.callWasAnswered  = false
        }

        let update = CXCallUpdate()
        update.remoteHandle        = CXHandle(type: .phoneNumber, value: callerNumber.isEmpty ? "Unknown" : callerNumber)
        update.localizedCallerName = callerName
        update.hasVideo            = false
        update.supportsHolding     = false
        update.supportsDTMF        = false

        callKitLogger.log("Reporting new incoming call to system", category: "CALLKIT")
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error = error {
                callKitLogger.error("reportIncomingCall failed: \(error.localizedDescription)")
                // CallKit rejected it (maybe phone is locked with Do Not Disturb)
                // Still notify the app so state is consistent
                self?.stateQueue.sync {
                    self?.activeCallUUID  = nil
                    self?.callWasAnswered = false
                }
            } else {
                callKitLogger.log("reportIncomingCall succeeded", category: "CALLKIT")
            }
        }
    }

    // Called by bridge when Android says call ended
    func endCall() {
        callKitLogger.log("endCall called", category: "CALLKIT")
        var uuid: UUID?
        stateQueue.sync { uuid = activeCallUUID }

        guard let callUUID = uuid else { return }

        provider.reportCall(with: callUUID, endedAt: Date(), reason: .remoteEnded)
        stateQueue.sync {
            self.activeCallUUID  = nil
            self.callWasAnswered = false
        }
    }

    // Called when user taps End in our UI
    func endCallFromApp() {
        callKitLogger.log("endCallFromApp called", category: "CALLKIT")
        var uuid: UUID?
        stateQueue.sync { uuid = activeCallUUID }

        guard let callUUID = uuid else { return }

        let action = CXEndCallAction(call: callUUID)
        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error = error {
                callKitLogger.error("endCallFromApp: \(error)")
            }
            self?.stateQueue.sync {
                self?.activeCallUUID  = nil
                self?.callWasAnswered = false
            }
        }
    }

    // FIXED: Check if already answered to prevent duplicate callbacks
    private func tryAnswerCall() {
        var alreadyAnswered = false
        stateQueue.sync { alreadyAnswered = callWasAnswered }

        guard !alreadyAnswered else { return }

        callKitLogger.log("tryAnswerCall: configuring audio and invoking callback", category: "CALLKIT")
        configureAudioSession()
        stateQueue.sync { self.callWasAnswered = true }
        onCallAnswered?()
    }
}

// MARK: - CXProviderDelegate
extension CallKitManager: CXProviderDelegate {

    // User swiped Accept
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        tryAnswerCall()
        action.fulfill()
    }

    // User swiped Decline OR tapped End while in call
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        var wasAnswered = false
        stateQueue.sync {
            wasAnswered = callWasAnswered
            self.callWasAnswered = false
            self.activeCallUUID  = nil
        }

        action.fulfill()

        if wasAnswered {
            onCallEnded?()      // was in a call — tell Android to hang up
        } else {
            onCallRejected?()   // was ringing — tell Android to reject
        }
    }

    // Audio session activated by CallKit
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // FIXED: Don't reconfigure if already configured this session
        if !audioSessionConfigured {
            configureAudioSession()
            audioSessionConfigured = true
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        callKitLogger.log("didDeactivate called", category: "CALLKIT")
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionConfigured = false
        }
        catch { callKitLogger.error("Deactivate: \(error)") }
    }

    // CallKit reset (e.g. after an error) — clean up state
    func providerDidReset(_ provider: CXProvider) {
        callKitLogger.log("providerDidReset called - cleaning up state", category: "CALLKIT")
        stateQueue.sync {
            self.activeCallUUID  = nil
            self.callWasAnswered = false
        }
        audioSessionConfigured = false
    }

    // FIXED: Improved audio session configuration
    private func configureAudioSession() {
        callKitLogger.log("configureAudioSession called", category: "AUDIO")
        let session = AVAudioSession.sharedInstance()
        do {
            // Use voice chat mode which has better compatibility
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.allowBluetoothHFP, .defaultToSpeaker])

            // Request reasonable sample rate instead of forcing 8000
            // iOS hardware typically supports 44100 or 48000
            try session.setPreferredSampleRate(44100)
            try session.setPreferredIOBufferDuration(0.005) // 5ms buffer for low latency
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            callKitLogger.log("Audio session configured: sampleRate=\(session.sampleRate)", category: "AUDIO")
        } catch {
            callKitLogger.error("Audio session error: \(error)")
            // Fallback to basic configuration
            do {
                try session.setCategory(.playAndRecord, mode: .default)
                try session.setActive(true)
            } catch {
                callKitLogger.error("Audio session fallback failed: \(error)")
            }
        }
    }
}
