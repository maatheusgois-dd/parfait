import Foundation
import os

/// Unified debug logging. Writes to unified log (Console.app:
/// subsystem `io.github.matheusgois-dd.Nutola`). When Developer mode is on,
/// also mirrors to the in-app Debug panel and stderr.
enum NutolaConsoleLog {
    private static let zoom = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "platform")
    private static let recording = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "recording")
    private static let pipeline = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "pipeline")
    private static let detection = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "detection")
    private static let live = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "live")
    private static let transcribe = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "transcribe")
    private static let speakers = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "speakers")
    private static let calendar = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "calendar")
    private static let app = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "app")
    private static let ask = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "ask")
    private static let diarizer = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "diarizer")
    private static let locales = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "locales")
    private static let notification = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "notification")
    private static let processing = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "processing")
    private static let intelligence = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "intelligence")
    private static let nemotron = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "nemotron")
    private static let soniqo = Logger(subsystem: "io.github.matheusgois-dd.Nutola", category: "soniqo")

    static func zoom(_ message: String) { emit(zoom, "zoom", message) }
    static func recording(_ message: String) { emit(recording, "recording", message) }
    static func pipeline(_ message: String) { emit(pipeline, "pipeline", message) }
    static func detection(_ message: String) { emit(detection, "detection", message) }
    static func live(_ message: String) { emit(live, "live", message) }
    static func transcribe(_ message: String) { emit(transcribe, "transcribe", message) }
    static func speakers(_ message: String) { emit(speakers, "speakers", message) }
    static func calendar(_ message: String) { emit(calendar, "calendar", message) }
    static func app(_ message: String) { emit(app, "app", message) }
    static func ask(_ message: String) { emit(ask, "ask", message) }
    static func diarizer(_ message: String) { emit(diarizer, "diarizer", message) }
    static func locales(_ message: String) { emit(locales, "locales", message) }
    static func notification(_ message: String) { emit(notification, "notification", message) }
    static func processing(_ message: String) { emit(processing, "processing", message) }
    static func intelligence(_ message: String) { emit(intelligence, "intelligence", message) }
    static func nemotron(_ message: String) { emit(nemotron, "nemotron", message) }
    static func soniqo(_ message: String) { emit(soniqo, "soniqo", message) }

    private static func emit(_ logger: Logger, _ category: String, _ message: String) {
        logger.info("\(message, privacy: .public)")
        mirror(category, message)
    }

    private static func mirror(_ category: String, _ message: String) {
        guard AppSettings.developerMode else { return }
        let line = "\(category): \(message)"
        fputs("[Nutola] \(line)\n", stderr)
        AIDebugLog.log(line)
    }
}
