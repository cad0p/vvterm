import Foundation
import Combine
import AVFoundation

struct AudioCaptureCleanupPlan: Equatable {
    let removeTap: Bool
    let stopEngine: Bool
    let deactivateAudioSession: Bool

    init(hasEngine: Bool, tapInstalled: Bool, audioSessionActive: Bool) {
        removeTap = hasEngine && tapInstalled
        stopEngine = hasEngine
        deactivateAudioSession = audioSessionActive
    }
}

@MainActor
final class AudioCaptureService: ObservableObject {
    @Published var audioLevel: Float = 0.0
    @Published var recordingDuration: TimeInterval = 0

    var bufferHandler: ((AVAudioPCMBuffer) -> Void)?

    private let targetSampleRate: Double = 16_000
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var recordedSamples: [Float] = []
    private var isRecording = false
    private var isTapInstalled = false
    private var isAudioSessionActive = false

    var sampleRate: Double { targetSampleRate }

    func start(lifecycleState: () -> AudioCaptureLifecycleState) throws {
        if isRecording { return }
        guard lifecycleState().allowsCapture else {
            throw RecordingError.inactiveLifecycle
        }

        cleanupCaptureResources()

        recordedSamples.removeAll(keepingCapacity: true)
        audioLevel = 0
        recordingDuration = 0

        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: [])
            isAudioSessionActive = true
            #endif

            let engine = AVAudioEngine()
            audioEngine = engine
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            if let rejection = AudioCaptureStartupPolicy.rejection(
                lifecycle: lifecycleState(),
                sampleRate: inputFormat.sampleRate,
                channelCount: Int(inputFormat.channelCount)
            ) {
                switch rejection {
                case .inactiveLifecycle:
                    throw RecordingError.inactiveLifecycle
                case .unavailableInputFormat:
                    throw RecordingError.inputUnavailable
                }
            }

            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            ) else {
                throw RecordingError.inputUnavailable
            }
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw RecordingError.converterUnavailable
            }
            self.converter = converter

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.handleBuffer(buffer, inputFormat: inputFormat, targetFormat: targetFormat)
            }
            isTapInstalled = true

            engine.prepare()
            try engine.start()
            isRecording = true
        } catch {
            cleanupCaptureResources()
            throw error
        }
    }

    func stop() -> [Float] {
        let samples = isRecording ? recordedSamples : []
        isRecording = false
        cleanupCaptureResources()
        audioLevel = 0
        recordingDuration = 0
        recordedSamples.removeAll(keepingCapacity: false)
        return samples
    }

    func cancel() {
        _ = stop()
        recordedSamples.removeAll(keepingCapacity: false)
        audioLevel = 0
        recordingDuration = 0
    }

    private func cleanupCaptureResources() {
        let plan = AudioCaptureCleanupPlan(
            hasEngine: audioEngine != nil,
            tapInstalled: isTapInstalled,
            audioSessionActive: isAudioSessionActive
        )
        if plan.removeTap {
            audioEngine?.inputNode.removeTap(onBus: 0)
        }
        if plan.stopEngine {
            audioEngine?.stop()
        }
        #if os(iOS)
        if plan.deactivateAudioSession {
            // Release the session so system services (e.g. keyboard dictation) regain the mic.
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        #endif
        isTapInstalled = false
        isAudioSessionActive = false
        audioEngine = nil
        converter = nil
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        guard let converter else { return }

        let ratio = targetSampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if error != nil {
            Task { @MainActor in
                self.audioLevel = 0
            }
            return
        }

        guard let channelData = convertedBuffer.floatChannelData else { return }
        let frameLength = Int(convertedBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        Task { @MainActor in
            self.updateMetrics(with: samples)
            self.bufferHandler?(convertedBuffer)
        }
    }

    private func updateMetrics(with samples: [Float]) {
        guard !samples.isEmpty else { return }

        let sumSquares = samples.reduce(0.0) { $0 + ($1 * $1) }
        let rms = sqrt(sumSquares / Float(samples.count))
        audioLevel = min(max(rms * 3, 0.05), 1.0)

        recordedSamples.append(contentsOf: samples)
        recordingDuration = Double(recordedSamples.count) / targetSampleRate
    }

    enum RecordingError: LocalizedError {
        case converterUnavailable
        case inactiveLifecycle
        case inputUnavailable

        var errorDescription: String? {
            switch self {
            case .converterUnavailable:
                return "Failed to configure audio converter."
            case .inactiveLifecycle:
                return "Voice recording is only available while VVTerm is active."
            case .inputUnavailable:
                return "Audio input is temporarily unavailable."
            }
        }
    }
}
