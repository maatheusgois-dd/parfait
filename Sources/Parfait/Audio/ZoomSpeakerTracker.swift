import AppKit
import ApplicationServices
import Foundation

/// Polls the installed Zoom Workplace client during recording and logs who the
/// meeting UI marks as speaking. Events are written to `speaker_events.json`
/// and later correlated with the system-audio transcript.
final class ZoomSpeakerTracker: @unchecked Sendable {
    private let meetingID: UUID
    private let archive: MeetingArchive
    private let startDate: Date
    private let elapsedOffset: TimeInterval
    private let queue = DispatchQueue(label: "io.github.conrad-vanl.Parfait.zoom-speakers")
    private var timer: DispatchSourceTimer?
    private var events: [PlatformSpeakerEvent] = []
    private var open: (name: String, start: TimeInterval)?
    private var lastPersist = Date.distantPast
    private var lastReportedName: String?
    private var tickCount = 0
    private var emptyTickStreak = 0
    private var lastSummary = Date.distantPast

    /// Called on the main queue whenever the active remote speaker changes.
    var onActiveSpeaker: (@MainActor (String?) -> Void)?

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
        ParfaitConsoleLog.zoom(
            "start meeting=\(meetingID.uuidString.prefix(8)) accessibility=\(trusted)")
        guard trusted else {
            ParfaitConsoleLog.zoom("blocked — grant Accessibility to Parfait, then refocus the app")
            Task { @MainActor in AccessibilityPermission.request() }
            return
        }
        queue.async {
            guard self.timer == nil else {
                ParfaitConsoleLog.zoom("start skipped — timer already running")
                return
            }
            ParfaitConsoleLog.zoom("polling every 400ms")
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
            let saved = PlatformSpeakerTurnBuilder.normalized(self.events)
            ParfaitConsoleLog.zoom(
                "stop ticks=\(self.tickCount) events=\(saved.count) saved=\(saved.map { "\($0.name) \(String(format: "%.1f", $0.start))-\(String(format: "%.1f", $0.end))" }.joined(separator: ", "))")
            Task { @MainActor in self.onActiveSpeaker?(nil) }
        }
    }

    // MARK: - Internals

    private func logInitialScan() {
        let scan = ZoomActiveSpeakerReader.scan()
        ParfaitConsoleLog.zoom(
            "initial scan zoomPID=\(scan.zoomPID.map(String.init) ?? "nil") roster=[\(scan.roster.joined(separator: ", "))] active=[\(scan.active.joined(separator: ", "))]")
    }

    private func tick() {
        tickCount += 1
        let scan = ZoomActiveSpeakerReader.scan()
        let names = scan.active
        let t = now

        if names.isEmpty {
            emptyTickStreak += 1
            closeOpen(until: t)
            reportActive(nil)
        } else {
            emptyTickStreak = 0
            let primary = names[0]
            reportActive(primary)
            if let open, open.name != primary {
                events.append(PlatformSpeakerEvent(name: open.name, start: open.start, end: t))
                ParfaitConsoleLog.zoom(
                    "segment closed \(open.name) \(String(format: "%.1f", open.start))-\(String(format: "%.1f", t))s → now \(primary)")
                self.open = (primary, t)
            } else if open == nil {
                open = (primary, t)
                ParfaitConsoleLog.zoom("segment opened \(primary) @ \(String(format: "%.1f", t))s")
            }
            persist(force: false)
        }

        let now = Date()
        if now.timeIntervalSince(lastSummary) >= 5 {
            lastSummary = now
            ParfaitConsoleLog.zoom(
                "heartbeat ticks=\(tickCount) active=\(names.first ?? "none")\(names.count > 1 ? " all=[\(names.joined(separator: ", "))]" : "") roster=\(scan.roster.count) emptyStreak=\(emptyTickStreak) events=\(events.count) elapsed=\(String(format: "%.0f", t))s")
            if names.isEmpty, !scan.roster.isEmpty {
                ParfaitConsoleLog.zoom(
                    "no active speaker tile — roster: [\(scan.roster.joined(separator: ", "))]")
            }
            if scan.roster.isEmpty {
                ParfaitConsoleLog.zoom(
                    "no participant tiles found — is Zoom in a meeting? pid=\(scan.zoomPID.map(String.init) ?? "nil")")
            }
        }
    }

    private func reportActive(_ name: String?) {
        let previous = lastReportedName
        guard name != previous else { return }
        lastReportedName = name
        if let name {
            ParfaitConsoleLog.zoom("active speaker → \(name)")
        } else if previous != nil {
            ParfaitConsoleLog.zoom("active speaker cleared")
        }
        Task { @MainActor in onActiveSpeaker?(name) }
    }

    private func closeOpen(until end: TimeInterval) {
        guard let open else { return }
        if end > open.start {
            events.append(PlatformSpeakerEvent(name: open.name, start: open.start, end: end))
        }
        self.open = nil
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
            ParfaitConsoleLog.zoom("persisted \(normalized.count) events to speaker_events.json")
        }
    }
}

// MARK: - Zoom AX reader

enum ZoomActiveSpeakerReader {
    struct ScanResult: Sendable {
        var zoomPID: pid_t?
        var roster: [String]
        var active: [String]
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
            return ScanResult(zoomPID: nil, roster: [], active: [])
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == mainBundleID
        }) else {
            return ScanResult(zoomPID: nil, roster: [], active: [])
        }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        var roster: [String] = []
        var activeTiles: [String] = []
        var activeLabels: [String] = []
        walk(root, depth: 0, roster: &roster, activeTiles: &activeTiles, activeLabels: &activeLabels)
        let rosterOut = deduped(roster)
        // Gallery tiles list every unmuted participant; only trust explicit
        // "active speaker" markers on those tiles. Legacy labels (participants
        // panel, notifications) are a fallback when no tile is marked.
        let activeOut = deduped(activeTiles.isEmpty ? activeLabels : activeTiles)
            .filter { !isLocalParticipant($0) }
        return ScanResult(
            zoomPID: app.processIdentifier,
            roster: rosterOut,
            active: activeOut)
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
        activeLabels: inout [String]
    ) {
        guard depth < 20 else { return }

        let r = role(element)
        if r == "AXTabGroup" || r == "AXGroup" {
            if let desc = attribute(element, kAXDescriptionAttribute as CFString) {
                if let name = parseZoomParticipantDescription(desc) {
                    roster.append(name)
                }
                if let name = parseZoomTileDescription(desc) {
                    activeTiles.append(name)
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
        }

        for child in children(element) {
            walk(child, depth: depth + 1, roster: &roster, activeTiles: &activeTiles, activeLabels: &activeLabels)
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
}
