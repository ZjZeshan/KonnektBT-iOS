// KonnektBT/Services/AudioStreamManager.swift
import Foundation
import AVFAudio

class AudioStreamManager: ObservableObject {

    // FIXED: Use lazy initialization instead of reassignment
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var inputTapInstalled = false

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 8000, channels: 1, interleaved: false)!

    private var isRunning = false
    var onCapturedAudio: ((Data) -> Void)?

    // FIXED: Thread-safe state management
    private let stateQueue = DispatchQueue(label: "com.konnekt.audio.state")

    func start() {
        stateQueue.sync {
            guard !isRunning else { return }
            isRunning = true
        }

        do {
            setupEngine()
            try audioEngine?.start()
        } catch {
            print("[Audio] Engine failed: \(error)")
            stateQueue.sync { self.isRunning = false }
            cleanupEngine()
        }
    }

    private func setupEngine() {
        // FIXED: Don't recreate if already setup, just return
        guard audioEngine == nil else { return }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: targetFormat)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // FIXED: Store reference before installing tap
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processMicAudio(buffer)
        }

        inputTapInstalled = true
        engine.prepare()

        audioEngine = engine
        playerNode = player
    }

    private func cleanupEngine() {
        if inputTapInstalled, let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }

        playerNode?.stop()
        playerNode = nil

        if let engine = audioEngine {
            engine.stop()
            // FIXED: Detach player node before releasing
            if let player = playerNode {
                engine.detach(player)
            }
        }
        audioEngine = nil
    }

    func playAudio(_ pcmData: Data) {
        guard let player = playerNode, let engine = audioEngine, engine.isRunning else { return }

        let sampleCount = pcmData.count / 2
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                           frameCapacity: AVAudioFrameCount(sampleCount))
        else { return }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        guard let floatCh = buffer.floatChannelData?[0] else { return }

        pcmData.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount { floatCh[i] = Float(ptr[i]) / 32768.0 }
        }

        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer)
    }

    private func processMicAudio(_ buffer: AVAudioPCMBuffer) {
        guard let resampled = resample(buffer) else { return }

        // FIXED: Use correct resampled data length
        let count = Int(resampled.frameLength)
        var data = Data(count: count * 2)

        guard let floatData = resampled.floatChannelData?[0] else { return }

        data.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                // FIXED: Proper Int16 conversion with clamping
                let clamped = max(-1.0, min(1.0, floatData[i]))
                ptr[i] = Int16(clamped * 32767.0)
            }
        }
        onCapturedAudio?(data)
    }

    // FIXED: Proper AVAudioConverter resampling implementation
    private func resample(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.sampleRate == 8000 { return buffer }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return nil
        }

        // Calculate output frame capacity
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return nil
        }

        var conversionError: NSError?
        var inputConsumed = false

        // FIXED: Proper conversion loop
        converter.convert(to: outputBuffer, error: &conversionError) { inNumPackets, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = conversionError {
            print("[Audio] Resample error: \(error)")
            return nil
        }

        return outputBuffer
    }

    func stop() {
        var wasRunning = false
        stateQueue.sync {
            wasRunning = isRunning
            isRunning = false
        }

        guard wasRunning else { return }

        if inputTapInstalled, let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }

        playerNode?.stop()

        if let engine = audioEngine {
            engine.stop()
            // FIXED: Detach all nodes properly
            if let player = playerNode {
                engine.detach(player)
            }
        }

        playerNode = nil
        audioEngine = nil
    }
}
