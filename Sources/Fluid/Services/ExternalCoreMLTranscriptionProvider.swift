import Foundation

#if arch(arm64)
import FluidAudio

@available(macOS 15.0, *)
final class ExternalCoreMLTranscriptionProvider: TranscriptionProvider {
    let name = "External CoreML"

    var isAvailable: Bool { true }
    private(set) var isReady: Bool = false
    var prefersNativeFileTranscription: Bool { true }

    private var cohereManager: CohereTranscribeAsrManager?
    private let modelOverride: SettingsStore.SpeechModel?

    init(modelOverride: SettingsStore.SpeechModel? = nil) {
        self.modelOverride = modelOverride
    }

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        guard self.isReady == false else { return }

        let model = self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
        DebugLogger.shared.info(
            "ExternalCoreML: prepare requested for model=\(model.rawValue)",
            source: "ExternalCoreML"
        )
        guard let spec = model.externalCoreMLSpec else {
            DebugLogger.shared.error(
                "ExternalCoreML: missing spec for model=\(model.rawValue)",
                source: "ExternalCoreML"
            )
            throw Self.makeError("No external CoreML spec registered for \(model.displayName).")
        }
        guard let directory = SettingsStore.shared.externalCoreMLArtifactsDirectory(for: model) else {
            DebugLogger.shared.error(
                "ExternalCoreML: no artifacts directory configured for model=\(model.rawValue)",
                source: "ExternalCoreML"
            )
            throw Self.makeError("Select the \(model.displayName) artifacts folder before loading the model.")
        }

        DebugLogger.shared.info(
            "ExternalCoreML: validating artifacts at \(directory.path)",
            source: "ExternalCoreML"
        )

        do {
            try spec.validateArtifactsOrThrow(at: directory)
            DebugLogger.shared.info(
                "ExternalCoreML: artifact validation passed for \(directory.lastPathComponent)",
                source: "ExternalCoreML"
            )
        } catch {
            DebugLogger.shared.error(
                "ExternalCoreML: artifact validation failed: \(error.localizedDescription)",
                source: "ExternalCoreML"
            )
            throw Self.makeError(error.localizedDescription)
        }

        progressHandler?(0.1)

        switch spec.backend {
        case .cohereTranscribe:
            let manager = CohereTranscribeAsrManager()
            progressHandler?(0.35)
            DebugLogger.shared.info(
                "ExternalCoreML: loading Cohere models [computeUnits=\(String(describing: spec.computeUnits))]",
                source: "ExternalCoreML"
            )
            try await manager.loadModels(from: directory, computeUnits: spec.computeUnits)
            self.cohereManager = manager
        }

        self.isReady = true
        DebugLogger.shared.info(
            "ExternalCoreML: provider ready for model=\(model.rawValue)",
            source: "ExternalCoreML"
        )
        progressHandler?(1.0)
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult {
        guard let manager = self.cohereManager else {
            DebugLogger.shared.error(
                "ExternalCoreML: file transcription requested before manager initialization",
                source: "ExternalCoreML"
            )
            throw Self.makeError("External CoreML model is not initialized.")
        }

        let startedAt = Date()
        DebugLogger.shared.info(
            "ExternalCoreML: native file transcription start [file=\(fileURL.lastPathComponent)]",
            source: "ExternalCoreML"
        )
        let text = try await manager.transcribe(audioFileAt: fileURL)
        let elapsed = Date().timeIntervalSince(startedAt)
        DebugLogger.shared.info(
            "ExternalCoreML: native file transcription finished in \(String(format: "%.2f", elapsed))s [chars=\(text.count)]",
            source: "ExternalCoreML"
        )
        return ASRTranscriptionResult(text: text, confidence: 1.0)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let manager = self.cohereManager else {
            DebugLogger.shared.error(
                "ExternalCoreML: transcribe requested before manager initialization",
                source: "ExternalCoreML"
            )
            throw Self.makeError("External CoreML model is not initialized.")
        }
        let startedAt = Date()
        let sampleRate = Double((self.modelOverride ?? SettingsStore.shared.selectedSpeechModel).externalCoreMLSpec?.expectedSampleRate ?? 16_000)
        let audioSeconds = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        DebugLogger.shared.debug(
            "ExternalCoreML: transcribing \(samples.count) samples [audioSeconds=\(String(format: "%.2f", audioSeconds))]",
            source: "ExternalCoreML"
        )
        let text = try await manager.transcribe(audioSamples: samples)
        let elapsed = Date().timeIntervalSince(startedAt)
        let rtf = audioSeconds > 0 ? elapsed / audioSeconds : 0
        DebugLogger.shared.info(
            "ExternalCoreML: transcription finished in \(String(format: "%.2f", elapsed))s [audioSeconds=\(String(format: "%.2f", audioSeconds)), rtf=\(String(format: "%.2fx", rtf)), chars=\(text.count)]",
            source: "ExternalCoreML"
        )
        return ASRTranscriptionResult(text: text, confidence: 1.0)
    }

    func modelsExistOnDisk() -> Bool {
        let model = self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
        guard
            let spec = model.externalCoreMLSpec,
            let directory = SettingsStore.shared.externalCoreMLArtifactsDirectory(for: model)
        else {
            return false
        }
        return spec.validateArtifacts(at: directory)
    }

    func clearCache() async throws {
        let model = self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
        guard
            model.externalCoreMLSpec != nil,
            let directory = SettingsStore.shared.externalCoreMLArtifactsDirectory(for: model)
        else {
            self.isReady = false
            self.cohereManager = nil
            return
        }

        let compiledDirectory = CohereTranscribeAsrModels.compiledArtifactsDirectory(for: directory)

        if FileManager.default.fileExists(atPath: compiledDirectory.path) {
            DebugLogger.shared.info(
                "ExternalCoreML: clearing compiled cache at \(compiledDirectory.path)",
                source: "ExternalCoreML"
            )
            try FileManager.default.removeItem(at: compiledDirectory)
        }

        self.isReady = false
        self.cohereManager = nil
        DebugLogger.shared.info(
            "ExternalCoreML: provider reset after cache clear",
            source: "ExternalCoreML"
        )
    }

    private static func makeError(_ description: String) -> NSError {
        NSError(
            domain: "ExternalCoreMLTranscriptionProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

#else

final class ExternalCoreMLTranscriptionProvider: TranscriptionProvider {
    let name = "External CoreML"
    let isAvailable = false
    let isReady = false

    init(modelOverride: SettingsStore.SpeechModel? = nil) {}

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        throw NSError(
            domain: "ExternalCoreMLTranscriptionProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "External CoreML models are only supported on Apple Silicon Macs."]
        )
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw NSError(
            domain: "ExternalCoreMLTranscriptionProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "External CoreML models are only supported on Apple Silicon Macs."]
        )
    }
}

#endif
