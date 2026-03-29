// KonnektBT/Services/AudioStreamManager.swift
import Foundation
import AVFAudio

class AudioStreamManager: ObservableObject {

    // Audio Specifications:
    // - Sample Rate: 16,000 Hz (16kHz)
    // - Bit Depth: 16-bit Linear PCM
    // - Channels: Mono

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var inputTapInstalled = false

    // Target format: 16kHz, Mono, Float32 (will convert to Int16 for sending)
    private let targetSampleRate: Double = 16000
    private let targetChannels: AVAudioChannelCount = 1

    private var isRunning = false
    var onCapturedAudio: ((Data) -> Void)?

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
        guard audioEngine == nil else { return }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)

        // Use native format for playback
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Install tap on input
        inputNode.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { [weak self] buffer, _ in
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
            if let player = playerNode {
                engine.detach(player)
            }
        }
        audioEngine = nil
    }

    func playAudio(_ pcmData: Data) {
        guard let player = playerNode,
              let engine = audioEngine,
              engine.isRunning else { return }

        let sampleCount = pcmData.count / 2  // 16-bit = 2 bytes per sample
        guard sampleCount > 0 else { return }

        // Create buffer with interleaved format
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: targetSampleRate,
                                         channels: targetChannels,
                                         interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: AVAudioFrameCount(sampleCount))
        else { return }

        buffer.frameLength = AVAudioFrameCount(sampleCount)

        // Copy PCM data to buffer
        pcmData.withUnsafeBytes { rawPtr in
            if let dest = buffer.int16ChannelData?[0] {
                let src = rawPtr.bindMemory(to: Int16.self)
                for i in 0..<sampleCount {
                    dest[i] = src[i]
                }
            }
        }

        if !player.isPlaying {
            player.play()
        }
        player.scheduleBuffer(buffer)
    }

    private func processMicAudio(_ buffer: AVAudioPCMBuffer) {
        // Convert to target format (16kHz mono)
        guard let converted = convertToTargetFormat(buffer) else { return }

        let frameCount = Int(converted.frameLength)
        var data = Data(count: frameCount * 2)  // 16-bit = 2 bytes

        // Convert float to Int16
        if let floatChannel = converted.floatChannelData?[0] {
            data.withUnsafeMutableBytes { rawPtr in
                let int16Ptr = rawPtr.bindMemory(to: Int16.self)
                for i in 0..<frameCount {
                    let sample = floatChannel[i]
                    // Clamp and convert
                    let clamped = max(-1.0, min(1.0, sample))
                    int16Ptr[i] = Int16(clamped * 32767.0)
                }
            }
        }

        onCapturedAudio?(data)
    }

    private func convertToTargetFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // If already 16kHz mono float, return as-is
        if buffer.format.sampleRate == targetSampleRate && buffer.format.channelCount == 1 {
            return buffer
        }

        // Create target format
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: targetSampleRate,
                                               channels: targetChannels,
                                               interleaved: false) else {
            return nil
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return nil
        }

        let ratio = targetSampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                  frameCapacity: outputFrameCount) else {
            return nil
        }

        var error: NSError?
        var inputConsumed = false

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            print("[Audio] Convert error: \(error)")
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
            if let player = playerNode {
                engine.detach(player)
            }
        }

        playerNode = nil
        audioEngine = nil
    }
}
