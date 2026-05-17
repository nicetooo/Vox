import AVFoundation
import Foundation

/// Records audio from the microphone using AVAudioEngine.
/// Saves as WAV file suitable for Whisper.
class AudioRecorder {
    let outputPath = "/tmp/znote_recording.wav"

    /// Callback reporting current audio level (0.0 - 1.0), called on audio thread
    var onAudioLevel: ((Float) -> Void)?

    /// Peak audio level observed during current recording (0.0 - 1.0, normalized)
    private(set) var peakLevel: Float = 0.0

    /// Recording start time
    private(set) var recordingStartTime: Date?

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?

    /// Whether the last recording had enough speech to be worth transcribing
    var hasMeaningfulAudio: Bool {
        let duration = recordingDuration
        let peak = peakLevel
        let threshold = Settings.shared.silenceThreshold
        let minDuration = Settings.shared.minRecordingDuration
        log("Audio check: duration=\(String(format: "%.1f", duration))s, peak=\(String(format: "%.3f", peak)), threshold=\(String(format: "%.2f", threshold)), minDur=\(String(format: "%.1f", minDuration))s")
        return duration >= minDuration && peak >= threshold
    }

    /// Duration of the last recording in seconds
    var recordingDuration: TimeInterval {
        guard let start = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(start)
    }

    func startRecording() {
        // Reset tracking
        peakLevel = 0.0
        recordingStartTime = Date()

        // Clean up previous recording
        try? FileManager.default.removeItem(atPath: outputPath)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        // Create output file — write as 16-bit PCM WAV at hardware sample rate.
        // mlx_whisper handles resampling internally.
        let url = URL(fileURLWithPath: outputPath)
        let writeSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: hardwareFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        do {
            audioFile = try AVAudioFile(
                forWriting: url,
                settings: writeSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            log("AudioRecorder: Failed to create audio file: \(error)")
            return
        }

        // Install tap — receive audio buffers from mic
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self = self, let file = self.audioFile else { return }

            // Calculate audio level for visualization + silence detection
            let level = self.calculateRMSLevel(buffer: buffer)
            if level > self.peakLevel { self.peakLevel = level }
            self.onAudioLevel?(level)

            // Write to file
            if hardwareFormat.channelCount > 1 {
                guard let monoBuffer = self.mixToMono(buffer: buffer) else { return }
                try? file.write(from: monoBuffer)
            } else {
                try? file.write(from: buffer)
            }
        }

        do {
            try engine.start()
            self.audioEngine = engine
        } catch {
            log("AudioRecorder: Failed to start audio engine: \(error)")
        }
    }

    func stopRecording() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
    }

    /// Calculate RMS audio level from buffer, returns 0.0 to 1.0
    private func calculateRMSLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sum: Float = 0
        let data = channelData[0]
        for i in 0..<frameCount {
            sum += data[i] * data[i]
        }
        let rms = sqrt(sum / Float(frameCount))

        // Convert to 0-1 range with amplification for better visualization
        // Typical speech RMS is around 0.01-0.1
        // Use sqrt for more dynamic range — small sounds are more visible
        let normalized = min(sqrt(rms) * 2.5, 1.0)
        return normalized
    }

    /// Mix a multi-channel buffer down to mono
    private func mixToMono(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 1,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: buffer.format.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let monoBuffer = AVAudioPCMBuffer(
                  pcmFormat: monoFormat,
                  frameCapacity: buffer.frameLength
              )
        else { return nil }

        monoBuffer.frameLength = buffer.frameLength

        guard let srcChannels = buffer.floatChannelData,
              let dstChannel = monoBuffer.floatChannelData
        else { return nil }

        let frameCount = Int(buffer.frameLength)
        // Average all channels
        for frame in 0..<frameCount {
            var sum: Float = 0
            for ch in 0..<channelCount {
                sum += srcChannels[ch][frame]
            }
            dstChannel[0][frame] = sum / Float(channelCount)
        }

        return monoBuffer
    }
}
