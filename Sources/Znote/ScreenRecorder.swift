import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

/// Records a region of the main display to an H.264 MOV file using
/// ScreenCaptureKit (macOS 13+) for capture and AVAssetWriter for muxing.
///
/// Coordinates: callers pass `region` in NSScreen / window coords (bottom-left
/// origin, global across screens) — same as what `RegionSelector` returns.
/// Internally we convert to top-left display-local coords for SCStreamConfiguration.
@available(macOS 13.0, *)
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    // MARK: - State

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false

    private(set) var isRecording = false
    private(set) var currentOutputURL: URL?

    // Receive sample buffers off the main queue so capture isn't blocked by UI.
    private let sampleQueue = DispatchQueue(label: "com.znote.recorder.samples", qos: .userInteractive)

    // MARK: - Public API

    /// Start recording the rectangle on the main display. Throws if the system
    /// rejects the stream (e.g. user denied Screen Recording permission, or the
    /// region resolves to zero pixels).
    func start(region: NSRect, output: URL) async throws {
        guard !isRecording else {
            throw NSError(domain: "Znote.ScreenRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Already recording"])
        }

        // 1. Find the NSScreen the region's center sits on, then map that to an SCDisplay.
        //    Hard-coding main display fails when the user selects on an external display:
        //    the resulting sourceRect lands outside the main display's bounds and SC
        //    rejects the stream with EINVAL ("参数无效导致失败").
        let regionCenter = NSPoint(x: region.midX, y: region.midY)
        let nsScreen: NSScreen
        if let s = NSScreen.screens.first(where: { $0.frame.contains(regionCenter) }) {
            nsScreen = s
        } else if let main = NSScreen.main {
            nsScreen = main
        } else if let first = NSScreen.screens.first {
            nsScreen = first
        } else {
            throw NSError(domain: "Znote.ScreenRecorder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No NSScreen available"])
        }
        let nsScreenID = (nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == nsScreenID })
                            ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                            ?? content.displays.first else {
            throw NSError(domain: "Znote.ScreenRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No display available"])
        }

        // 2. Convert region (global bottom-left) → display-local top-left
        let displayFrame = nsScreen.frame
        let localX = region.minX - displayFrame.minX
        let localY = displayFrame.maxY - region.maxY  // flip y within this display
        let sourceRect = CGRect(x: localX, y: localY, width: region.width, height: region.height)

        // 3. Build stream config. Output pixel dims = points × backingScale for
        //    native-resolution capture.
        let scale = nsScreen.backingScaleFactor
        let outW = max(2, Int((region.width * scale).rounded()))
        let outH = max(2, Int((region.height * scale).rounded()))

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = outW
        config.height = outH
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)  // 30 fps cap
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.showsCursor = true
        // System audio capture (what's playing through speakers, not the mic).
        // Covered by the same Screen Recording TCC permission — no extra prompt.
        if #available(macOS 13.0, *) {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }

        // Exclude all of Znote's own windows from the recording so the
        // floating stop button (and any other overlay we throw up) doesn't end
        // up baked into the video. Using `excludingApplications` covers
        // windows that appear AFTER the filter is created — important because
        // AppDelegate shows the stop pill right after this start() returns.
        let bid = Bundle.main.bundleIdentifier ?? "com.znote.app"
        let znoteApps = content.applications.filter { $0.bundleIdentifier == bid }
        let filter: SCContentFilter
        if znoteApps.isEmpty {
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            filter = SCContentFilter(display: display,
                                     excludingApplications: znoteApps,
                                     exceptingWindows: [])
        }

        log("ScreenRecorder: region=\(region) → sourceRect=\(sourceRect), output=\(outW)×\(outH) @ \(scale)x, excluded \(znoteApps.count) Znote app(s) → \(output.path)")

        // 5. AVAssetWriter pipeline.
        try? FileManager.default.removeItem(at: output)  // overwrite if exists
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let bitrate = max(4_000_000, Int(Double(outW * outH) * 0.12))  // ~6Mbps for 1080p
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "Znote.ScreenRecorder", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter rejected video input"])
        }
        writer.add(videoInput)

        // Audio input — AAC 48kHz stereo, ~128kbps.
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        if writer.canAdd(audioInput) {
            writer.add(audioInput)
        } else {
            // Audio input failed for some reason — fall back to video-only.
            log("ScreenRecorder: writer rejected audio input, recording video only")
        }

        // 6. SCStream + output hookup (both video and audio).
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        } catch {
            log("ScreenRecorder: failed to add audio output: \(error.localizedDescription) — video only")
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = writer.inputs.contains(audioInput) ? audioInput : nil
        self.stream = stream
        self.currentOutputURL = output
        self.sessionStarted = false
        self.isRecording = true

        try await stream.startCapture()
    }

    /// Stop recording. Returns the output URL on success, nil if the writer
    /// failed for any reason. Safe to call when not recording (returns nil).
    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false

        let stream = self.stream
        let writer = self.writer
        let video = self.videoInput
        let audio = self.audioInput
        let url = self.currentOutputURL

        // Stop capture first so no more samples arrive.
        do {
            try await stream?.stopCapture()
        } catch {
            log("ScreenRecorder: stopCapture error: \(error.localizedDescription)")
        }

        // Tell the writer no more data is coming, then await finalisation.
        video?.markAsFinished()
        audio?.markAsFinished()
        if writer?.status == .writing {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                writer?.finishWriting { cont.resume() }
            }
        }

        let success = writer?.status == .completed
        if !success {
            log("ScreenRecorder: write failed — status=\(writer?.status.rawValue ?? -1), err=\(writer?.error?.localizedDescription ?? "n/a")")
        } else {
            log("ScreenRecorder: stopped, saved \(url?.path ?? "?")")
        }

        self.stream = nil
        self.writer = nil
        self.videoInput = nil
        self.audioInput = nil
        self.currentOutputURL = nil
        self.sessionStarted = false

        return success ? url : nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer = writer else { return }

        // Screen frames carry a status attachment — skip non-complete ones
        // (idle / blank / queue-empty etc.). Audio buffers don't have it.
        if type == .screen {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]] ?? []
            if let statusVal = attachments.first?[.status] as? Int,
               let status = SCFrameStatus(rawValue: statusVal),
               status != .complete {
                return
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // First sample of either kind establishes the writer's session base.
        // AVAssetWriter requires every sample to be at PTS ≥ session start,
        // so we pick whichever stream arrives first.
        if !sessionStarted {
            if writer.status == .unknown {
                writer.startWriting()
                writer.startSession(atSourceTime: pts)
            }
            sessionStarted = true
        }

        switch type {
        case .screen:
            if let v = videoInput, v.isReadyForMoreMediaData {
                v.append(sampleBuffer)
            }
        case .audio:
            if let a = audioInput, a.isReadyForMoreMediaData {
                a.append(sampleBuffer)
            }
        @unknown default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("ScreenRecorder: SCStream stopped with error: \(error.localizedDescription)")
    }
}
