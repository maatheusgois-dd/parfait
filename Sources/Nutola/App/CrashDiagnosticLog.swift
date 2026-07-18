import Foundation

@_silgen_name("openat")
private func c_openat(_ fd: Int32, _ path: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32

/// Writes a scrubbed, bounded diagnostic record to disk when the app crashes, so
/// a maintainer's first GitHub issue isn't "it crashed, here's nothing."
///
/// Opt-in via `AppSettings.crashDiagnostics` (default off). When enabled, `install()`
/// hooks:
///   - `NSSetUncaughtExceptionHandler` for uncaught Obj-C exceptions (runs on the
///     crashing thread before the process dies; Foundation is safe there).
///   - `sigaction` for `SIGABRT`, `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE` (runs in
///     signal context, where only async-signal-safe calls are allowed).
///
/// What it records (never audio, transcript, or summary text):
///   - app version, macOS version, timestamp
///   - signal number or exception name + reason
///   - the in-flight meeting's id, title, state, and notice (via a snapshot closure
/// The most recent crash is also mirrored to `diagnostics.json` (back-comat), and
/// every crash is appended as its own file under `Crashes/` (capped at 20, oldest
/// pruned) so the Debug tab can show a history with titles and per-crash detail.
enum CrashDiagnosticLog {
    /// Set at launch by AppState so the crash record can name the in-flight meeting
    /// without touching audio/transcript files. Returns nil when nothing is recording.
    /// Must be safe to call from any context (signal handlers capture it before they
    /// run, and the exception handler runs on the crashing thread).
    nonisolated(unsafe) static var inFlightMeetingSnapshot: (@Sendable () -> InFlightMeeting?)?

    struct InFlightMeeting: Sendable {
        let id: String
        let title: String
        let state: String
        let notice: String?
    }

    /// Pre-computed at install() time (Foundation-safe) so the signal handler never
    /// touches FileManager/URL/Swift String — only async-signal-safe C calls.
    private nonisolated(unsafe) static var diagnosticsPathC: [CChar] = []
    /// Per-crash history dir, pre-computed (Foundation-safe at install time) so the
    /// signal handler can build a unique filename per crash without allocating.
    private nonisolated(unsafe) static var crashesDirC: [CChar] = []
    private nonisolated(unsafe) static var versionC: [CChar] = []

    // MARK: - Resolved paths (Foundation-safe contexts only)

    /// The per-app Application Support directory (`…/Nutola`). Not used by the
    /// signal handler, which reads the pre-computed C strings (`crashesDirC` etc.)
    /// instead — Foundation is unsafe in a signal context.
    private static var nutolaSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Nutola", isDirectory: true)
    }

    /// The crash-history directory (`…/Nutola/Crashes`). Centralizing it here
    /// replaces the six repeated `base.appendingPathComponent("Nutola/Crashes")`
    /// lookups across `writeRecord`/`allCrashes`/`text`/`pruneHistory`/`delete`/
    /// `clearAllCrashes`.
    private static var crashReportsDirectory: URL {
        nutolaSupportDirectory.appendingPathComponent("Crashes", isDirectory: true)
    }

    /// Installs the exception + signal handlers. Call once, early in `Bootstrap.main()`
    /// before `NutolaApp.main()`. No-op when the user hasn't opted in.
    static func install() {
        guard AppSettings.crashDiagnostics else { return }

        // Resolve the output paths + version as C strings now (Foundation is safe
        // here, but NOT in the signal handler).
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let nutolaDir = base.appendingPathComponent("Nutola", isDirectory: true)
        try? FileManager.default.createDirectory(at: nutolaDir, withIntermediateDirectories: true)
        let crashesDir = nutolaDir.appendingPathComponent("Crashes", isDirectory: true)
        try? FileManager.default.createDirectory(at: crashesDir, withIntermediateDirectories: true)
        diagnosticsPathC = Array(nutolaDir.appendingPathComponent("diagnostics.json").path.utf8CString)
        crashesDirC = Array(crashesDir.path.utf8CString)
        versionC = Array(Bootstrap.version.utf8CString)

        // Prune the crash history at launch so the cap holds even if many crashes
        // happened between launches.
        pruneHistory()

        // Obj-C exceptions (NSException) — runs on the crashing thread, Foundation-safe.
        NSSetUncaughtExceptionHandler { exception in
            CrashDiagnosticLog.writeRecord(
                kind: "exception",
                detail: "\(exception.name.rawValue): \(exception.reason ?? "(no reason)")",
                callstack: exception.callStackSymbols)
        }

        // Signals — run in signal context; only async-signal-safe calls allowed.
        for signo in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { signum in
                CrashDiagnosticLog.handleSignal(signum)
            }
            action.sa_mask = 0
            action.sa_flags = 0
            sigaction(signo, &action, nil)
        }
    }

    /// Async-signal-safe signal handler. Builds a minimal JSON record using ONLY
    /// async-signal-safe C calls (strcpy/strcat/strlen/open/write/close/gettimeofday/
    /// signal/raise) into a stack buffer. No Swift String, no interpolation, no
    /// allocation, no Foundation — those abort/deadlock in a signal handler.
    ///
    /// The record is intentionally small: version + timestamp + signal name. We skip
    /// the in-flight meeting snapshot (the closure may allocate) and the callstack
    /// (callStackSymbols allocates); the exception handler captures both for Obj-C
    /// exceptions, which is the common macOS crash path.
    private static func handleSignal(_ signo: Int32) {
        // Capture the time once, before the buffer-building closure, so both the
        // JSON body and the per-crash filename share the same timestamp.
        var timeValue = timeval()
        gettimeofday(&timeValue, nil)
        // 512 bytes is far more than enough for our tiny record; if it ever
        // truncates, the worst case is a partial but still-terminated JSON line.
        var buffer = [CChar](repeating: 0, count: 512)
        let written = buffer.withUnsafeMutableBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            var pos = 0
            func append(_ literal: StaticString) {
                let bytes = literal.withUTF8Buffer { ptr in
                    Array(ptr.prefix(while: { $0 != 0 }))
                }
                for byte in bytes where pos < buf.count - 1 {
                    base[pos] = CChar(bitPattern: byte)
                    pos += 1
                }
            }
            func appendC(_ cstr: UnsafePointer<CChar>) {
                var index = 0
                while pos < buf.count - 1, cstr[index] != 0 {
                    base[pos] = cstr[index]
                    pos += 1
                    index += 1
                }
            }
            func appendInt64(_ value: Int64) {
                // Max 20 digits + sign; write backwards into a temp then copy.
                var temp = [CChar](repeating: 0, count: 24)
                var tempLen = 0
                var value = value
                if value == 0 {
                    temp[0] = 48 // '0'
                    tempLen = 1
                } else {
                    while value > 0, tempLen < temp.count {
                        temp[tempLen] = CChar(48 + Int(value % 10))
                        value /= 10
                        tempLen += 1
                    }
                }
                for index in stride(from: tempLen - 1, through: 0, by: -1) where pos < buf.count - 1 {
                    base[pos] = temp[index]
                    pos += 1
                }
            }
            append("{\"version\":\"")
            versionC.withUnsafeBufferPointer { ptr in
                if let basePtr = ptr.baseAddress { appendC(basePtr) }
            }
            append("\",\"timestamp\":")
            appendInt64(Int64(timeValue.tv_sec))
            append(",\"kind\":\"signal\",\"detail\":\"")
            append(signalLiteral(signo))
            append("\"}")
            return pos
        }
        if written > 0 {
            // Mirror to diagnostics.json (latest, back-comat) and also write a unique
            // per-crash file under Crashes/ so the Debug tab can list history. Both
            // use the same pre-computed C-string paths + the already-built buffer.
            let pathPtr = diagnosticsPathC.withUnsafeBufferPointer { $0.baseAddress }
            guard let latestPath = pathPtr else {
                reRaise(signo)
                return
            }
            writeFile(latestPath, buffer: buffer, count: written)
            let crashPath = buildCrashFilePath(timestamp: Int64(timeValue.tv_sec), signo: signo)
            writeFile(crashPath, buffer: buffer, count: written)
        }
        reRaise(signo)
    }

    private static func reRaise(_ signo: Int32) {
        Foundation.signal(signo, SIG_DFL)
        Foundation.raise(signo)
    }

    /// Writes `count` bytes of `buffer` to `path` (async-signal-safe: c_openat +
    /// write + close). No-op on any failure.
    private static func writeFile(_ path: UnsafePointer<CChar>, buffer: [CChar], count: Int) {
        let descriptor = c_openat(AT_FDCWD, path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if descriptor >= 0 {
            _ = buffer.withUnsafeBufferPointer { buf -> Int in
                Foundation.write(descriptor, buf.baseAddress, count)
            }
            close(descriptor)
        }
    }

    /// Builds "<crashesDir>/crash-<epoch>-<signo>.json" as a C string in a stack
    /// buffer. Async-signal-safe: copies the pre-computed dir, appends the
    /// filename (literal + decimal epoch + signo) digit by digit.
    private static func buildCrashFilePath(timestamp: Int64, signo: Int32) -> UnsafePointer<CChar> {
        // crashesDir + "/crash-" + digits(epoch) + "-" + digits(signo) + ".json\0"
        var path = [CChar](repeating: 0, count: 1024)
        path.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var pos = 0
            func appendC(_ cstr: UnsafePointer<CChar>) {
                var index = 0
                while pos < buf.count - 1, cstr[index] != 0 {
                    base[pos] = cstr[index]; pos += 1; index += 1
                }
            }
            func appendStatic(_ literal: StaticString) {
                literal.withUTF8Buffer { ptr in
                    for byte in ptr where pos < buf.count - 1 {
                        base[pos] = CChar(bitPattern: byte); pos += 1
                    }
                }
            }
            func appendInt64(_ value: Int64) {
                var temp = [CChar](repeating: 0, count: 24)
                var tempLen = 0
                var value = value
                if value == 0 { temp[0] = 48; tempLen = 1 }
                else {
                    while value > 0, tempLen < temp.count {
                        temp[tempLen] = CChar(48 + Int(value % 10)); value /= 10; tempLen += 1
                    }
                }
                for index in stride(from: tempLen - 1, through: 0, by: -1) where pos < buf.count - 1 {
                    base[pos] = temp[index]; pos += 1
                }
            }
            crashesDirC.withUnsafeBufferPointer { ptr in
                if let dirPtr = ptr.baseAddress { appendC(dirPtr) }
            }
            appendStatic("/crash-")
            appendInt64(timestamp)
            appendStatic("-")
            appendInt64(Int64(signo))
            appendStatic(".json")
        }
        // Leak intentionally: the signal handler can't manage heap lifetime. The
        // path is needed only for the single write right after, and the bytes are
        // tiny (a few dozen per crash, capped at 20 crashes). The leak is bounded
        // and only on the crash path (process is about to die anyway).
        return path.withUnsafeBufferPointer { $0.baseAddress! }
    }

    /// Foundation-based write (exception path — runs on the crashing thread, not in
    /// signal context, so JSONSerialization and File I/O are safe).
    private static func writeRecord(kind: String, detail: String, callstack: [String]) {
        let inFlight: Any = {
            if let snapshot = inFlightMeetingSnapshot?() {
                return [
                    "id": snapshot.id,
                    "title": snapshot.title,
                    "state": snapshot.state,
                    "notice": snapshot.notice as Any,
                ] as [String: Any]
            }
            return NSNull()
        }()
        let payload: [String: Any] = [
            "version": Bootstrap.version,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "kind": kind,
            "detail": detail,
            "callstack": callstack,
            "inFlight": inFlight,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: nutolaSupportDirectory.appendingPathComponent("diagnostics.json"), options: .atomic)
            // Per-crash history: <Crashes>/crash-<epochMS>-exception.json
            let crashesDir = crashReportsDirectory
            try? FileManager.default.createDirectory(at: crashesDir, withIntermediateDirectories: true)
            let epochMS = Int64(Date().timeIntervalSince1970 * 1000)
            let name = "crash-\(epochMS)-exception.json"
            try? data.write(to: crashesDir.appendingPathComponent(name), options: .atomic)
            pruneHistory()
        }
    }

    /// Reads all crash records from `Crashes/`, newest first. Used by the Debug tab.
    struct CrashRecord: Identifiable, Equatable, Sendable {
        let id: String           // filename (stable)
        let timestamp: Date
        let kind: String         // "signal" or "exception"
        let detail: String       // signal name or exception name: reason
        let title: String        // human label for the list

        var relativeTime: String {
            CalendarTimeFormatter.time(timestamp)
        }
    }
    /// Lists every crash file in `Crashes/`, newest first. Empty when none.
    static func allCrashes() -> [CrashRecord] {
        let crashesDir = crashReportsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: crashesDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("crash-") })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
        else { return [] }
        return files.compactMap { file -> CrashRecord? in
            // Parse the minimal fields out of the JSON; fall back to the filename.
            guard let data = try? Data(contentsOf: file),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            let id = file.lastPathComponent
            let kind = (object["kind"] as? String) ?? "unknown"
            let detail = (object["detail"] as? String) ?? id
            // Timestamp: signal path stores an Int epoch; exception path stores ISO8601.
            let timestamp: Date
            if let epoch = (object["timestamp"] as? NSNumber)?.int64Value, epoch > 1_000_000_000_000 {
                timestamp = Date(timeIntervalSince1970: TimeInterval(epoch) / 1000)
            } else if let epoch = (object["timestamp"] as? NSNumber)?.int64Value {
                timestamp = Date(timeIntervalSince1970: TimeInterval(epoch))
            } else if let iso = object["timestamp"] as? String,
                      let parsed = ISO8601DateFormatter().date(from: iso) {
                timestamp = parsed
            } else {
                return nil
            }
            let title = "\(kind): \(detail)"
            return CrashRecord(id: id, timestamp: timestamp, kind: kind, detail: detail, title: title)
        }
    }

    /// Full text of one crash record (the raw JSON, pretty), for the detail view.
    static func text(for record: CrashRecord) -> String {
        let url = crashReportsDirectory.appendingPathComponent(record.id)
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return "(unreadable crash record: \(record.id))" }
        let pretty = (try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\(object)"
        return pretty
    }

    /// Concatenate every crash record into one text block, for "Copy All".
    static func allCrashesText() -> String {
        let records = allCrashes()
        if records.isEmpty { return "(no crashes recorded)" }
        return records.map { record in
            "════════════════════════════════════════════\n"
                + "\(record.title)  ·  \(record.relativeTime)  ·  \(record.id)\n"
                + "────────────────────────────────────────────\n"
                + text(for: record)
        }.joined(separator: "\n\n")
    }

    /// Removes the oldest crash files past the cap (20), keeping newest first.
    /// Safe to call from `install()` and after each `writeRecord`.
    private static func pruneHistory() {
        let crashesDir = crashReportsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: crashesDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("crash-") })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
        else { return }
        guard files.count > 20 else { return }
        for file in files.dropFirst(20) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Deletes one crash record file. Safe to call from the UI.
    static func delete(_ record: CrashRecord) {
        try? FileManager.default.removeItem(at: crashReportsDirectory.appendingPathComponent(record.id))
    }

    /// Deletes every recorded crash. Safe to call from the UI.
    static func clearAllCrashes() {
        let crashesDir = crashReportsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: crashesDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("crash-") })
        else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Static-string signal name (async-signal-safe; no allocation).
    private static func signalLiteral(_ signo: Int32) -> StaticString {
        switch signo {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        default: return "SIGUNKNOWN"
        }
    }
}
