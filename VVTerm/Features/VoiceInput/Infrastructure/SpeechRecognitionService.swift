import Foundation
import Combine
import Speech
import AVFoundation

@MainActor
class SpeechRecognitionService: ObservableObject {
    @Published var transcribedText = ""
    @Published var partialTranscription = ""

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognizerLanguageCode: String?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

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

    func startRecognition() async throws {
        guard let speechRecognizer = resolvedRecognizer(), speechRecognizer.isAvailable else {
            throw SpeechRecognitionError.recognitionUnavailable
        }

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        self.recognitionRequest = recognitionRequest
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let transcription = result.bestTranscription.formattedString

                Task { @MainActor in
                    if result.isFinal {
                        self.transcribedText = transcription
                    } else {
                        self.partialTranscription = transcription
                    }
                }
            }

            if error != nil || result?.isFinal == true {
                // No audio engine to stop here; AudioCaptureService handles input
            }
        }
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    func stopRecognition() async -> String {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        // Wait for final transcription
        try? await Task.sleep(for: .milliseconds(500))

        let finalText = transcribedText.isEmpty ? partialTranscription : transcribedText
        return finalText
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        guard let speechRecognizer = resolvedRecognizer(), speechRecognizer.isAvailable else {
            throw SpeechRecognitionError.recognitionUnavailable
        }

        recognitionTask?.cancel()
        recognitionTask = nil

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
                        self?.recognitionTask = nil
                    }
                    continuation.resume(throwing: error)
                    return
                }

                guard let result else { return }
                if result.isFinal {
                    finished = true
                    cleanup()
                    Task { @MainActor in
                        self?.recognitionTask = nil
                    }
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    func cancelRecognition() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        transcribedText = ""
        partialTranscription = ""
    }

    func resetTranscriptions() {
        transcribedText = ""
        partialTranscription = ""
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
