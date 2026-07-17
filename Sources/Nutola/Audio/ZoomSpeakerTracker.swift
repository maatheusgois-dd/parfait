import Foundation
import AppKit
import ApplicationServices

/// Polls the installed Zoom Workplace client during recording and logs who the
/// meeting UI marks as speaking. Events are written to `speaker_events.json`
/// and later correlated with the system-audio transcript.
final class ZoomSpeakerTracker: PlatformSpeakerTracker, @unchecked Sendable {
    private let meetingID: UUID
    private let archive: MeetingArchive
    private let startDate: Date
    private let elapsedOffset: TimeInterval
    private let queue = DispatchQueue(label: "io.github.matheusgois-dd.Nutola.zoom-speakers")
    private var timer: DispatchSourceTimer?
    private var events: [PlatformSpeakerEvent] = []
    private var open: (name: String, start: TimeInterval, source: PlatformSpeakerSource)?
    private var lastPersist = Date.distantPast
    private var lastReportedName: String?
    private var tickCount = 0
    private var emptyTickStreak = 0
    private var lastSummary = Date.distantPast
    private var lastCaptionKey: String?
    private var lastRoster: [String] = []
    private var rosterPersisted = false

    /// Called on the main queue whenever the active remote speaker changes.
    var onActiveSpeaker: (@MainActor (String?) -> Void)?
    /// Thread-safe snapshot of the active speaker name at a given elapsed time.
    /// Called from the LiveTranscriber's handle() to attribute system-audio
    /// segments to the Zoom-reported speaker instead of generic "Others".
    func speakerAt(_ t: TimeInterval) -> String? {
        queue.sync {
            // Check the open segment first (most recent), then walk events backward.
            if let open, t >= open.start {
                return open.name
            }
            for event in events.reversed() where t >= event.start && t < event.end {
                return event.name
            }
            return nil
        }
    }

    /// Thread-safe snapshot of the current participant roster.
    func currentRoster() -> [String] {
        queue.sync { lastRoster }
    }

    init(
        meetingID: UUID,
        archive: MeetingArchive,
        startDate: Date,
        elapsedOffset: TimeInterval = 0
    ) {
        self.meetingID = meetingID
        self.archive = archive
        self.startDate = startDate
        self.elapsedOffset = elapsedOffset
    }

    func start() {
        let trusted = AccessibilityPermission.isTrusted
        NutolaConsoleLog.zoom(
            "start meeting=\(meetingID.uuidString.prefix(8)) accessibility=\(trusted)")
        guard trusted else {
            NutolaConsoleLog.zoom("blocked — grant Accessibility to Nutola, then refocus the app")
            Task { @MainActor in AccessibilityPermission.request() }
            return
        }
        queue.async {
            guard self.timer == nil else {
                NutolaConsoleLog.zoom("start skipped — timer already running")
                return
            }
            NutolaConsoleLog.zoom("polling every 400ms")
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.4)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
            self.logInitialScan()
        }
    }

    func stop() {
        queue.sync {
            self.timer?.cancel()
            self.timer = nil
            self.closeOpen(until: self.now)
            self.persist(force: true)
            // Always persist the final roster so the batch pipeline can attribute
            // speaker names even if the roster never changed during the call
            // (the tick() save is gated on roster change, which never fires for
            // a stable participant list — leaving no zoom_roster.json behind).
            if !self.lastRoster.isEmpty {
                self.archive.saveZoomRoster(self.lastRoster, for: self.meetingID)
                NutolaConsoleLog.zoom("stop: persisted final roster (\(self.lastRoster.count) names)")
            }
            let saved = PlatformSpeakerTurnBuilder.normalized(self.events)
            NutolaConsoleLog.zoom(
                "stop ticks=\(self.tickCount) events=\(saved.count) saved=\(saved.map { "\($0.name) \(String(format: "%.1f", $0.start))-\(String(format: "%.1f", $0.end))" }.joined(separator: ", "))")
            Task { @MainActor in self.onActiveSpeaker?(nil) }
        }
    }

    // MARK: - Internals

    private func logInitialScan() {
        let scan = ZoomActiveSpeakerReader.scan()
        NutolaConsoleLog.zoom(
            "initial scan zoomPID=\(scan.zoomPID.map(String.init) ?? "nil") roster=[\(scan.roster.joined(separator: ", "))] active=[\(scan.active.joined(separator: ", "))] captions=\(scan.latestCaption.map { "\($0.name): \($0.text.prefix(40))" } ?? "none")")
        // Full AX tree dump for debugging — reveals tile descriptions, roles, and
        // attributes the parsers might miss. Logged at .info so it appears in Console.app.
        if scan.roster.isEmpty && scan.active.isEmpty {
            NutolaConsoleLog.zoom("no roster or active speakers found — dumping full AX tree for diagnosis")
            ZoomActiveSpeakerReader.dumpAXTree()
        }
    }

    private func tick() {
        tickCount += 1
        let scan = ZoomActiveSpeakerReader.scan()
        let names = scan.active
        let t = now

        recordCaption(scan.latestCaption, at: t)

        if names.isEmpty {
            emptyTickStreak += 1
            closeOpen(until: t)
            reportActive(nil)
        } else {
            emptyTickStreak = 0
            let primary = names[0]
            let source = scan.activeSource
            reportActive(primary)
            if let open, open.name != primary {
                events.append(PlatformSpeakerEvent(
                    name: open.name, start: open.start, end: t, source: open.source))
                NutolaConsoleLog.zoom(
                    "segment closed \(open.name) \(String(format: "%.1f", open.start))-\(String(format: "%.1f", t))s → now \(primary)")
                self.open = (primary, t, source)
            } else if open == nil {
                open = (primary, t, source)
                NutolaConsoleLog.zoom("segment opened \(primary) @ \(String(format: "%.1f", t))s (\(source.rawValue))")
            }
            persist(force: false)
        }

        // Persist the roster whenever it changes, OR on the first non-empty scan
        // (the change-gating alone never fires for a stable participant list, so the
        // batch pipeline would find no zoom_roster.json and lose all speaker names).
        if scan.roster != lastRoster || (!scan.roster.isEmpty && !rosterPersisted) {
            lastRoster = scan.roster
            archive.saveZoomRoster(scan.roster, for: meetingID)
            rosterPersisted = true
        }

        let now = Date()
        if now.timeIntervalSince(lastSummary) >= 5 {
            lastSummary = now
            NutolaConsoleLog.zoom(
                "heartbeat ticks=\(tickCount) active=\(names.first ?? "none")\(names.count > 1 ? " all=[\(names.joined(separator: ", "))]" : "") roster=\(scan.roster.count) emptyStreak=\(emptyTickStreak) events=\(events.count) elapsed=\(String(format: "%.0f", t))s")
            if names.isEmpty, !scan.roster.isEmpty {
                NutolaConsoleLog.zoom(
                    "no active speaker tile — roster: [\(scan.roster.joined(separator: ", "))]")
            }
            if scan.roster.isEmpty {
                NutolaConsoleLog.zoom(
                    "no participant tiles found — is Zoom in a meeting? pid=\(scan.zoomPID.map(String.init) ?? "nil")")
            }
        }
    }

    private func reportActive(_ name: String?) {
        let previous = lastReportedName
        guard name != previous else { return }
        lastReportedName = name
        if let name {
            NutolaConsoleLog.zoom("active speaker → \(name)")
        } else if previous != nil {
            NutolaConsoleLog.zoom("active speaker cleared")
        }
        Task { @MainActor in onActiveSpeaker?(name) }
    }

    private func closeOpen(until end: TimeInterval) {
        guard let open else { return }
        if end > open.start {
            events.append(PlatformSpeakerEvent(
                name: open.name, start: open.start, end: end, source: open.source))
        }
        self.open = nil
    }

    /// Captures a short caption window when Zoom live transcript exposes speaker-prefixed lines.
    private func recordCaption(_ caption: ZoomActiveSpeakerReader.CaptionLine?, at t: TimeInterval) {
        guard let caption else { return }
        let key = "\(caption.name)|\(caption.text)"
        guard key != lastCaptionKey else { return }
        lastCaptionKey = key
        let start = max(0, t - 1.5)
        events.append(PlatformSpeakerEvent(
            name: caption.name, start: start, end: t, source: .caption))
        NutolaConsoleLog.zoom("caption \(caption.name): \(caption.text.prefix(60))")
        persist(force: false)
    }

    private var now: TimeInterval {
        elapsedOffset + Date().timeIntervalSince(startDate)
    }

    private func persist(force: Bool) {
        let current = Date()
        guard force || current.timeIntervalSince(lastPersist) >= 2 else { return }
        lastPersist = current
        let normalized = PlatformSpeakerTurnBuilder.normalized(events)
        archive.savePlatformSpeakerEvents(normalized, for: meetingID)
        if force || normalized.count % 3 == 0 {
            NutolaConsoleLog.zoom("persisted \(normalized.count) events to speaker_events.json")
        }
    }
}

// MARK: - Zoom AX reader

enum ZoomActiveSpeakerReader {
    struct CaptionLine: Sendable, Equatable {
        var name: String
        var text: String
    }

    struct ScanResult: Sendable {
        var zoomPID: pid_t?
        var roster: [String]
        var active: [String]
        var activeSource: PlatformSpeakerSource
        var latestCaption: CaptionLine?
    }

    private static let mainBundleID = "us.zoom.xos"

    private static let ignoredExact: Set<String> = [
        "zoom", "zoom workplace", "zoom meeting", "zoom webinar",
        "mute", "unmute", "mute audio", "unmute audio", "mute my audio",
        "start video", "stop video", "participants", "chat", "share screen",
        "share", "reactions", "security", "polls", "breakout rooms", "more",
        "leave", "end", "end meeting", "leave meeting", "raise hand",
        "lower hand", "closed caption", "live transcript", "view", "record",
        "apps", "whiteboards", "you", "me", "host", "co-host", "guest",
    ]

    static func scan() -> ScanResult {
        guard AccessibilityPermission.isTrusted else {
            return ScanResult(
                zoomPID: nil, roster: [], active: [], activeSource: .activeSpeaker,
                latestCaption: nil)
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == mainBundleID
        }) else {
            return ScanResult(
                zoomPID: nil, roster: [], active: [], activeSource: .activeSpeaker,
                latestCaption: nil)
        }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        var roster: [String] = []
        var activeTiles: [String] = []
        var activeLabels: [String] = []
        var selectedTiles: [String] = []
        var latestCaption: CaptionLine?
        // Use kAXWindowsAttribute to get ALL windows, including those on other
        // screens/Spaces. kAXChildrenAttribute on the app root may miss windows
        // that aren't on the active Space or are on a secondary display.
        let windows = allWindows(root)
        if windows.isEmpty {
            // Fallback: walk from the root if windows attribute is empty.
            walk(
                root, depth: 0, roster: &roster, activeTiles: &activeTiles,
                activeLabels: &activeLabels, selectedTiles: &selectedTiles,
                latestCaption: &latestCaption)
        } else {
            for window in windows {
                walk(
                    window, depth: 0, roster: &roster, activeTiles: &activeTiles,
                    activeLabels: &activeLabels, selectedTiles: &selectedTiles,
                    latestCaption: &latestCaption)
            }
        }
        let rosterOut = deduped(roster)
        // Gallery tiles list every unmuted participant; only trust explicit
        // "active speaker" markers on those tiles. Legacy labels (participants
        // panel, notifications) are a fallback when no tile is marked.
        let (activeOut, source): ([String], PlatformSpeakerSource)
        if !activeTiles.isEmpty {
            activeOut = activeTiles
            source = .activeSpeaker
        } else if !activeLabels.isEmpty {
            activeOut = activeLabels
            source = .activeSpeaker
        } else {
            activeOut = selectedTiles
            source = .selectedTile
        }
        return ScanResult(
            zoomPID: app.processIdentifier,
            roster: rosterOut,
            active: deduped(activeOut).filter { !isLocalParticipant($0) },
            activeSource: source,
            latestCaption: latestCaption)
    }

    /// Diagnostic: dumps the full Zoom AX tree (first ~500 elements) to the unified
    /// log. Run at recording start and on demand to debug why speaker names aren't
    /// being detected — reveals tile descriptions, roles, and attributes that the
    /// parsers might be missing.
    static func dumpAXTree() {
        guard AccessibilityPermission.isTrusted else {
            NutolaConsoleLog.zoom("dumpAXTree — no Accessibility permission")
            return
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == mainBundleID
        }) else {
            NutolaConsoleLog.zoom("dumpAXTree — Zoom not running")
            return
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var count = 0
        let maxDump = 500
        func dump(_ element: AXUIElement, depth: Int) {
            guard count < maxDump else { return }
            let r = role(element)
            let desc = attribute(element, kAXDescriptionAttribute as CFString) ?? ""
            let title = attribute(element, kAXTitleAttribute as CFString) ?? ""
            let val = attribute(element, kAXValueAttribute as CFString) ?? ""
            let sel = isSelected(element)
            let indent = String(repeating: "  ", count: min(depth, 10))
            if !desc.isEmpty || !title.isEmpty || !val.isEmpty || r != "AXUnknown" {
                var parts = ["role=\(r)"]
                if !desc.isEmpty { parts.append("desc=\(desc.prefix(120))") }
                if !title.isEmpty { parts.append("title=\(title.prefix(80))") }
                if !val.isEmpty { parts.append("val=\(val.prefix(80))") }
                if sel { parts.append("SELECTED") }
                NutolaConsoleLog.zoom("AX[\(count)] \(indent)\(parts.joined(separator: " "))")
                count += 1
            }
            for child in children(element) {
                dump(child, depth: depth + 1)
                if count >= maxDump { break }
            }
        }
        NutolaConsoleLog.zoom("=== Zoom AX Tree Dump (pid=\(app.processIdentifier)) ===")
        let windows = allWindows(root)
        if windows.isEmpty {
            dump(root, depth: 0)
        } else {
            NutolaConsoleLog.zoom("(\(windows.count) windows found via kAXWindowsAttribute)")
            for window in windows {
                dump(window, depth: 0)
                if count >= maxDump { break }
            }
        }
        NutolaConsoleLog.zoom("=== AX Tree Dump: \(count) elements ===")
    }

    /// True when Zoom's display name matches the Mac account holder (local mic).
    static func isLocalParticipant(_ name: String) -> Bool {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return false }
        let nameL = name.lowercased()
        let fullL = full.lowercased()
        if nameL == fullL { return true }
        let nameParts = nameL.split(separator: " ")
        let fullParts = Set(fullL.split(separator: " "))
        guard !nameParts.isEmpty else { return false }
        return nameParts.allSatisfy { fullParts.contains($0) }
    }

    static func activeSpeakerNames() -> [String] {
        scan().active
    }

    private static func walk(
        _ element: AXUIElement,
        depth: Int,
        roster: inout [String],
        activeTiles: inout [String],
        activeLabels: inout [String],
        selectedTiles: inout [String],
        latestCaption: inout CaptionLine?
    ) {
        guard depth < 20 else { return }

        let r = role(element)
        if r == "AXTabGroup" || r == "AXGroup" {
            if let desc = attribute(element, kAXDescriptionAttribute as CFString) {
                if let name = parseZoomParticipantDescription(desc) {
                    roster.append(name)
                    if isSelected(element) {
                        selectedTiles.append(name)
                    }
                }
                if let name = parseZoomTileDescription(desc) {
                    activeTiles.append(name)
                }
            }
        }

        if r == "AXRow" || r == "AXOutlineRow" || r == "AXCell" {
            for key in [kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString,
                        kAXValueAttribute as CFString] {
                if let text = attribute(element, key), let name = parseParticipantRow(text) {
                    roster.append(name)
                }
            }
        }

        for text in [attribute(element, kAXDescriptionAttribute as CFString),
                     attribute(element, kAXTitleAttribute as CFString),
                     attribute(element, kAXValueAttribute as CFString)].compactMap({ $0 }) {
            guard !isParticipantTileDescription(text) else { continue }
            if let name = parseSpeakingLabel(text) {
                activeLabels.append(name)
            }
            if let caption = parseZoomCaptionLine(text) {
                latestCaption = caption
            }
        }

        for child in children(element) {
            walk(
                child, depth: depth + 1, roster: &roster, activeTiles: &activeTiles,
                activeLabels: &activeLabels, selectedTiles: &selectedTiles,
                latestCaption: &latestCaption)
        }
    }

    /// Zoom video tiles embed mic/video state — not a speaking indicator.
    private static func isParticipantTileDescription(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("computer audio") || lower.contains("video on") || lower.contains("video off")
    }

    /// Any video tile: `"Gui Lima, Computer audio unmuted, Video on"`.
    static func parseZoomParticipantDescription(_ raw: String) -> String? {
        let lower = raw.lowercased()
        guard lower.contains("computer audio") || lower.contains("video on") else { return nil }
        guard let comma = raw.firstIndex(of: ",") else { return nil }
        return cleaned(String(raw[..<comma]))
    }

    /// Active speaker tile: `"Gui Lima, Computer audio unmuted, Video on, active speaker"`.
    static func parseZoomTileDescription(_ raw: String) -> String? {
        let lower = raw.lowercased()
        guard lower.contains("active speaker") else { return nil }
        guard let comma = raw.firstIndex(of: ",") else { return nil }
        return cleaned(String(raw[..<comma]))
    }

    /// Parses legacy/alternate Zoom UI strings like `"Jimmy Veloso, unmuted"`.
    static func parseSpeakingLabel(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()

        let patterns: [String] = [
            #"^(.+?),\s*unmuted(?:\s+audio)?$"#,
            #"^(.+?)\s+is\s+speaking$"#,
            #"^(.+?)\s+is\s+talking$"#,
            #"^speaking:\s*(.+)$"#,
            #"^active\s+speaker:\s*(.+)$"#,
            #"^(.+?),\s*speaking$"#,
        ]
        for pattern in patterns {
            if let name = firstCapture(pattern: pattern, in: lower, original: text) {
                return cleaned(name)
            }
        }
        return nil
    }

    /// Zoom live-transcript / closed-caption lines: `"Gui Lima: hello everyone"`.
    static func parseZoomCaptionLine(_ raw: String) -> CaptionLine? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let patterns = [
            #"^(.+?)\s+said:\s+(.+)$"#,
            #"^(.+?):\s+(.+)$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges > 2,
                  let nameRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { continue }
            let name = String(text[nameRange])
            let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.count >= 2,
                  let cleanedName = cleaned(name),
                  !isParticipantTileDescription(text) else { continue }
            return CaptionLine(name: cleanedName, text: body)
        }
        return nil
    }

    /// Participants panel rows — plain display names without tile metadata.
    static func parseParticipantRow(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.contains("computer audio") || lower.contains("video on") || lower.contains("active speaker") {
            return nil
        }
        if lower.contains("participant") || lower.contains("meeting") || lower.contains("mute") {
            return nil
        }
        return cleaned(text)
    }

    private static func isSelected(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedAttribute as CFString, &value) == .success
        else { return false }
        return (value as? Bool) == true
    }

    private static func firstCapture(pattern: String, in lower: String, original: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(original.startIndex..<original.endIndex, in: original)
        guard let match = regex.firstMatch(in: original, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: original) else { return nil }
        return String(original[capture])
    }

    private static func cleaned(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard name.count >= 2, name.count <= 80 else { return nil }
        let lower = name.lowercased()
        if ignoredExact.contains(lower) { return nil }
        if lower.hasPrefix("zoom") { return nil }
        if name.allSatisfy({ $0.isNumber || $0.isWhitespace }) { return nil }
        if name.contains("@") { return nil }
        return name
    }

    private static func deduped(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in names {
            let key = name.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(name)
        }
        return out
    }

    private static func role(_ element: AXUIElement) -> String {
        attribute(element, kAXRoleAttribute as CFString) ?? "?"
    }

    private static func attribute(_ element: AXUIElement, _ key: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &value) == .success else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    /// Returns all windows from the application root element, including those on
    /// other screens, Spaces, or that are minimized. `kAXChildrenAttribute` misses
    /// these; `kAXWindowsAttribute` is the complete list.
    private static func allWindows(_ app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }
}
