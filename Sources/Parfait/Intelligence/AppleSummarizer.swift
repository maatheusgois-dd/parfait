import Foundation
import FoundationModels

enum AppleSummarizerError: LocalizedError {
    case unavailable(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .generationFailed(let message): return message
        }
    }
}

@Generable
private struct GeneratedTitle {
    @Guide(description: "Specific 3-8 word meeting title, no quotes, no trailing period")
    var title: String
}

enum AppleSummarizer {
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static var unavailableReason: String? {
        guard case .unavailable(let reason) = SystemLanguageModel.default.availability else { return nil }
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence isn't enabled on this Mac. Turn it on in System Settings to use on-device summaries."
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence."
        case .modelNotReady:
            return "The on-device model is still downloading. Try again in a few minutes."
        @unknown default:
            return "The on-device model is unavailable."
        }
    }

    /// ~55% of the context window for input; English ~3.5 chars/token (TN3193).
    static func fits(_ text: String) -> Bool {
        text.count <= inputBudgetChars
    }

    static func summarize(transcript: String, filledTemplate: String) async throws -> String {
        try ensureAvailable()
        let model = transformationModel
        let instructions = """
        You summarize meeting transcripts. Fill in the headings of the user's template from the \
        transcript, omitting any section with no content. Use speaker names as they appear in the \
        transcript. Output ONLY the finished markdown — no preamble or commentary.
        """
        let fullPrompt = "Template:\n\(filledTemplate)\n\nTranscript:\n\(transcript)"

        do {
            return try await respondOnce(model: model, instructions: instructions, prompt: fullPrompt)
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error else { throw wrap(error) }
        } catch {
            throw wrap(error)
        }

        // TN3193 map-reduce: fresh session per chunk, then combine partials against the template.
        do {
            let chunks = chunk(transcript)
            var partials: [String] = []
            for (i, piece) in chunks.enumerated() {
                let prompt = """
                Summarize part \(i + 1) of \(chunks.count) of a meeting transcript in at most \
                200 words. Keep decisions, action items, owners, and dates.

                \(piece)
                """
                partials.append(try await respondOnce(model: model, instructions: instructions, prompt: prompt))
            }
            let reducePrompt = "Template:\n\(filledTemplate)\n\n"
                + "Combine these partial summaries of one meeting into a single summary following the template:\n\n"
                + partials.joined(separator: "\n\n---\n\n")
            return try await respondOnce(model: model, instructions: instructions, prompt: reducePrompt)
        } catch {
            throw wrap(error)
        }
    }

    static func generateTitle(fromSummary summary: String) async throws -> String {
        try ensureAvailable()
        do {
            let session = LanguageModelSession(instructions: "You write short, specific meeting titles.")
            let response = try await session.respond(
                to: "Write a title for the meeting with this summary:\n\n\(summary)",
                generating: GeneratedTitle.self,
                options: GenerationOptions(temperature: 0.3)
            )
            var title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}"))
            if title.hasSuffix(".") { title = String(title.dropLast()) }
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw wrap(error)
        }
    }

    static func answer(question: String, context: String) async throws -> String {
        try ensureAvailable()
        let instructions = """
        You answer questions about a meeting using only the provided notes and transcript. \
        Be concise. If the material doesn't contain the answer, say so.
        """
        let prompt = "Material:\n\(context)\n\nQuestion: \(question)"
        do {
            // No map-reduce here: on overflow the caller routes the question to Claude.
            return try await respondOnce(model: transformationModel, instructions: instructions, prompt: prompt)
        } catch {
            throw wrap(error)
        }
    }

    // MARK: - Internals

    /// Relaxed guardrails for transformation tasks: meeting content is user-supplied,
    /// and default guardrails false-positive on sensitive-but-legitimate discussion.
    private static var transformationModel: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    private static var inputBudgetChars: Int {
        // contextSize is @backDeployed to 26.0 (fallback 4096) — don't hardcode.
        Int(Double(SystemLanguageModel.default.contextSize) * 0.55 * 3.5)
    }

    private static func ensureAvailable() throws {
        if let reason = unavailableReason {
            throw AppleSummarizerError.unavailable(reason)
        }
    }

    /// Fresh session per call: the 4096-token window covers instructions plus every turn
    /// in a session transcript, so reusing one session across calls overflows.
    private static func respondOnce(
        model: SystemLanguageModel,
        instructions: String,
        prompt: String,
        retryOnRateLimit: Bool = true
    ) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.3))
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            // A menu-bar (LSUIElement) app can count as background, where the system rate limit applies.
            if case .rateLimited = error, retryOnRateLimit {
                try await Task.sleep(for: .seconds(3))
                return try await respondOnce(
                    model: model, instructions: instructions, prompt: prompt, retryOnRateLimit: false
                )
            }
            throw error
        }
    }

    private static func chunk(_ text: String) -> [String] {
        let maxChars = inputBudgetChars
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > maxChars, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func wrap(_ error: Error) -> Error {
        if error is AppleSummarizerError { return error }
        return AppleSummarizerError.generationFailed(error.localizedDescription)
    }
}
