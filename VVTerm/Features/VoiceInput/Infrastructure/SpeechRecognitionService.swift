import Foundation
import Combine
import Speech
import AVFoundation

enum SpeechRecognitionOperationState: Equatable {
    case idle
    case running(UUID)
    case finishing(UUID)

    var generation: UUID? {
        switch self {
        case .idle:
            return nil
        case .running(let generation), .finishing(let generation):
            return generation
        }
    }

    func acceptsResult(for generation: UUID) -> Bool {
        self.generation == generation
    }
}

@MainActor
class SpeechRecognitionService: ObservableObject {
    @Published var transcribedText = ""
    @Published var partialTranscription = ""

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognizerLanguageCode: String?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionState: SpeechRecognitionOperationState = .idle
    private var recognitionCompletionStream: AsyncStream<Void>?
    private var recognitionCompletionContinuation: AsyncStream<Void>.Continuation?

    var isAvailable: Bool {
        resolvedRecognizer()?.isAvailable ?? false
    }

    // MARK: - Recognizer Resolution

    private static let preferredLocaleIdentifiers: [String: String] = [
        "en": "en-US",
        "es": "es-ES",
        "fr": "fr-FR",
        "de": "de-DE",
        "ja": "ja-JP",
        "zh": "zh-CN",
        "ko": "ko-KR",
        "pt": "pt-BR",
        "ru": "ru-RU"
    ]

    private func resolvedRecognizer() -> SFSpeechRecognizer? {
        let languageCode = TranscriptionSettingsStore.currentLanguageCode()
        if let speechRecognizer, recognizerLanguageCode == languageCode {
            return speechRecognizer
        }
        let recognizer = Self.makeRecognizer(languageCode: languageCode)
        speechRecognizer = recognizer
        recognizerLanguageCode = languageCode
        return recognizer
    }

    private static func makeRecognizer(languageCode: String) -> SFSpeechRecognizer? {
        for locale in candidateLocales(languageCode: languageCode) {
            if let recognizer = SFSpeechRecognizer(locale: locale) {
                return recognizer
            }
        }
        return SFSpeechRecognizer()
    }

    private static func candidateLocales(languageCode: String) -> [Locale] {
        guard languageCode != TranscriptionSettingsDefaults.autoLanguageCode else {
            return [Locale.current]
        }

        var identifiers: [String] = []
        if let preferred = preferredLocaleIdentifiers[languageCode] {
            identifiers.append(preferred)
        }
        let supportedMatches = SFSpeechRecognizer.supportedLocales()
            .filter { $0.language.languageCode?.identifier == languageCode }
            .map(\.identifier)
            .sorted()
        identifiers.append(contentsOf: supportedMatches)
        identifiers.append(languageCode)

        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            guard seen.insert(identifier).inserted else { return nil }
            return Locale(identifier: identifier)
        }
    }

    // MARK: - Recognition Control

    func startRecognition() throws {
        guard let speechRecognizer = resolvedRecognizer(), speechRecognizer.isAvailable else {
            throw SpeechRecognitionError.recognitionUnavailable
        }

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil
        finishRecognitionCompletion()

        let generation = UUID()
        recognitionState = .running(generation)
        let completion = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        recognitionCompletionStream = completion.stream
        recognitionCompletionContinuation = completion.continuation

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        self.recognitionRequest = recognitionRequest
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            let transcription = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let didComplete = error != nil || isFinal
            guard transcription != nil || didComplete else { return }

            Task { @MainActor [weak self, completionContinuation = completion.continuation] in
                guard let self, self.recognitionState.acceptsResult(for: generation) else { return }
                if let transcription {
                    if isFinal {
                        self.transcribedText = transcription
                    } else {
                        self.partialTranscription = transcription
                    }
                }
                if didComplete {
                    completionContinuation.yield()
                    completionContinuation.finish()
                }
            }
        }
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    func stopRecognition() async -> String {
        guard let generation = recognitionState.generation else {
            return transcribedText.isEmpty ? partialTranscription : transcribedText
        }
        recognitionState = .finishing(generation)
        let completionStream = recognitionCompletionStream
        recognitionRequest?.endAudio()
        recognitionTask?.finish()

        if let completionStream {
            await Self.waitForRecognitionCompletion(
                completionStream,
                timeout: .milliseconds(500)
            )
        }

        guard recognitionState == .finishing(generation) else { return "" }
        guard !Task.isCancelled else {
            cancelRecognition()
            return ""
        }
        let finalText = transcribedText.isEmpty ? partialTranscription : transcribedText
        recognitionState = .idle
        recognitionRequest = nil
        recognitionTask = nil
        finishRecognitionCompletion()
        return finalText
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        guard let speechRecognizer = resolvedRecognizer(), speechRecognizer.isAvailable else {
            throw SpeechRecognitionError.recognitionUnavailable
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        finishRecognitionCompletion()
        let generation = UUID()
        recognitionState = .running(generation)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vvterm-transcription-\(UUID().uuidString)")
            .appendingPathExtension("caf")

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)

        if let channel = buffer.floatChannelData?.pointee {
            samples.withUnsafeBufferPointer { ptr in
                channel.update(from: ptr.baseAddress!, count: samples.count)
            }
        }

        try file.write(from: buffer)

        let request = SFSpeechURLRecognitionRequest(url: tempURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false

        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let cleanup: () -> Void = {
                try? FileManager.default.removeItem(at: tempURL)
            }

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                if finished { return }

                if let error {
                    finished = true
                    cleanup()
                    Task { @MainActor in
                        guard self?.recognitionState.acceptsResult(for: generation) == true else { return }
                        self?.recognitionTask = nil
                        self?.recognitionState = .idle
                    }
                    continuation.resume(throwing: error)
                    return
                }

                guard let result else { return }
                if result.isFinal {
                    finished = true
                    cleanup()
                    Task { @MainActor in
                        guard self?.recognitionState.acceptsResult(for: generation) == true else { return }
                        self?.recognitionTask = nil
                        self?.recognitionState = .idle
                    }
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    func cancelRecognition() {
        recognitionState = .idle
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil
        finishRecognitionCompletion()

        transcribedText = ""
        partialTranscription = ""
    }

    func resetTranscriptions() {
        transcribedText = ""
        partialTranscription = ""
    }

    nonisolated static func waitForRecognitionCompletion(
        _ stream: AsyncStream<Void>,
        timeout: Duration
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in stream { break }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func finishRecognitionCompletion() {
        recognitionCompletionContinuation?.finish()
        recognitionCompletionContinuation = nil
        recognitionCompletionStream = nil
    }

    // MARK: - Errors

    enum SpeechRecognitionError: LocalizedError {
        case recognitionUnavailable

        var errorDescription: String? {
            switch self {
            case .recognitionUnavailable:
                return "Speech recognition is not available. Please enable Siri in System Settings > Siri & Spotlight."
            }
        }
    }
}
