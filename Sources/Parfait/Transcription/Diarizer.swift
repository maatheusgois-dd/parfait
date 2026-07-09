import FluidAudio
import Foundation

enum Diarizer {
    static func diarize(fileURL: URL) async throws -> [DiarizedTurn] {
        // OfflineDiarizerManager is non-Sendable: create + use within this scope only.
        let manager = OfflineDiarizerManager(config: .default)
        // First run downloads ~22 MB of Core ML models from HuggingFace; cached after.
        try await manager.prepareModels()
        let result = try await manager.process(fileURL)
        return result.segments
            .map {
                DiarizedTurn(
                    speaker: $0.speakerId,
                    start: TimeInterval($0.startTimeSeconds),
                    end: TimeInterval($0.endTimeSeconds)
                )
            }
            .sorted { $0.start < $1.start }
    }
}
