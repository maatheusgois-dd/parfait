import AppKit
import ApplicationServices
import Foundation

// zoom-info: standalone CLI that reads Zoom's Accessibility tree and prints
// the roster, active speaker, captions, and optional full AX tree dump.
// Mirrors ZoomActiveSpeakerReader exactly — what you see is what the app sees.
//
// Usage:
//   swift run zoom-info            → pretty-printed summary
//   swift run zoom-info --json     → machine-readable JSON
//   swift run zoom-info --dump     → include full AX tree dump (first 500)
//   swift run zoom-info --watch    → repeat every 2s until Ctrl-C

// MARK: - AX helpers

func axRole(_ e: AXUIElement) -> String {
    axAttr(e, kAXRoleAttribute as CFString) ?? "?"
}

func axAttr(_ e: AXUIElement, _ key: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, key, &value) == .success else { return nil }
    if let s = value as? String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    return nil
}

func axChildren(_ e: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value) == .success,
          let list = value as? [AXUIElement] else { return [] }
    return list
}

func axAllWindows(_ app: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let list = value as? [AXUIElement] else { return [] }
    return list
}

func axIsSelected(_ e: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXSelectedAttribute as CFString, &value) == .success
    else { return false }
    return (value as? Bool) == true
}

// MARK: - Parsing (mirrors ZoomActiveSpeakerReader)

let ignoredExact: Set<String> = [
    "zoom", "zoom workplace", "zoom meeting", "zoom webinar",
    "mute", "unmute", "mute audio", "unmute audio", "mute my audio",
    "start video", "stop video", "participants", "chat", "share screen",
    "share", "reactions", "security", "polls", "breakout rooms", "more",
    "leave", "end", "end meeting", "leave meeting", "raise hand",
    "lower hand", "closed caption", "live transcript", "view", "record",
    "apps", "whiteboards", "you", "me", "host", "co-host", "guest",
]

func cleanedName(_ raw: String) -> String? {
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

func isParticipantTileDescription(_ raw: String) -> Bool {
    let lower = raw.lowercased()
    return lower.contains("computer audio") || lower.contains("video on") || lower.contains("video off")
}

func parseZoomParticipantDescription(_ raw: String) -> String? {
    let lower = raw.lowercased()
    guard lower.contains("computer audio") || lower.contains("video on") else { return nil }
    guard let comma = raw.firstIndex(of: ",") else { return nil }
    return cleanedName(String(raw[..<comma]))
}

func parseZoomTileDescription(_ raw: String) -> String? {
    let lower = raw.lowercased()
    guard lower.contains("active speaker") else { return nil }
    guard let comma = raw.firstIndex(of: ",") else { return nil }
    return cleanedName(String(raw[..<comma]))
}

func parseParticipantRow(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let lower = text.lowercased()
    if lower.contains("computer audio") || lower.contains("video on") || lower.contains("active speaker") {
        return nil
    }
    if lower.contains("participant") || lower.contains("meeting") || lower.contains("mute") {
        return nil
    }
    return cleanedName(text)
}

func firstCapture(pattern: String, in original: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return nil
    }
    let range = NSRange(original.startIndex..<original.endIndex, in: original)
    guard let match = regex.firstMatch(in: original, range: range),
          match.numberOfRanges > 1,
          let capture = Range(match.range(at: 1), in: original) else { return nil }
    return String(original[capture])
}

func parseSpeakingLabel(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    let patterns: [String] = [
        #"^(.+?),\s*unmuted(?:\s+audio)?$"#,
        #"^(.+?)\s+is\s+speaking$"#,
        #"^(.+?)\s+is\s+talking$"#,
        #"^speaking:\s*(.+)$"#,
        #"^active\s+speaker:\s*(.+)$"#,
        #"^(.+?),\s*speaking$"#,
    ]
    for pattern in patterns {
        if let name = firstCapture(pattern: pattern, in: text) {
            return cleanedName(name)
        }
    }
    return nil
}

struct CaptionLine {
    var name: String
    var text: String
}

func parseZoomCaptionLine(_ raw: String) -> CaptionLine? {
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
              let cleanedNameVal = cleanedName(name),
              !isParticipantTileDescription(text) else { continue }
        return CaptionLine(name: cleanedNameVal, text: body)
    }
    return nil
}

func deduped(_ names: [String]) -> [String] {
    var seen = Set<String>()
    var out = [String]()
    for name in names {
        let key = name.lowercased()
        guard seen.insert(key).inserted else { continue }
        out.append(name)
    }
    return out
}

func isLocalParticipant(_ name: String) -> Bool {
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

// MARK: - Scan

struct ScanResult {
    var zoomPID: pid_t?
    var roster: [String] = []
    var active: [String] = []
    var activeSource: String = "activeSpeaker"
    var latestCaption: CaptionLine?
}

func zoomScan() -> ScanResult {
    guard AXIsProcessTrusted() else {
        return ScanResult(zoomPID: nil)
    }
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "us.zoom.xos"
    }) else {
        return ScanResult(zoomPID: nil)
    }

    let root = AXUIElementCreateApplication(app.processIdentifier)
    var roster = [String]()
    var activeTiles = [String]()
    var activeLabels = [String]()
    var selectedTiles = [String]()
    var latestCaption: CaptionLine?

    func walk(_ element: AXUIElement, depth: Int) {
        guard depth < 20 else { return }
        let r = axRole(element)

        if r == "AXTabGroup" || r == "AXGroup" {
            if let desc = axAttr(element, kAXDescriptionAttribute as CFString) {
                if let name = parseZoomParticipantDescription(desc) {
                    roster.append(name)
                    if axIsSelected(element) { selectedTiles.append(name) }
                }
                if let name = parseZoomTileDescription(desc) {
                    activeTiles.append(name)
                }
            }
        }

        if r == "AXRow" || r == "AXOutlineRow" || r == "AXCell" {
            for key in [kAXTitleAttribute as CFString, kAXDescriptionAttribute as CFString,
                        kAXValueAttribute as CFString] {
                if let text = axAttr(element, key), let name = parseParticipantRow(text) {
                    roster.append(name)
                }
            }
        }

        for text in [axAttr(element, kAXDescriptionAttribute as CFString),
                     axAttr(element, kAXTitleAttribute as CFString),
                     axAttr(element, kAXValueAttribute as CFString)].compactMap({ $0 }) {
            guard !isParticipantTileDescription(text) else { continue }
            if let name = parseSpeakingLabel(text) {
                activeLabels.append(name)
            }
            if let caption = parseZoomCaptionLine(text) {
                latestCaption = caption
            }
        }

        for child in axChildren(element) {
            walk(child, depth: depth + 1)
        }
    }

    let windows = axAllWindows(root)
    if windows.isEmpty {
        walk(root, depth: 0)
    } else {
        for window in windows {
            walk(window, depth: 0)
        }
    }

    let rosterOut = deduped(roster)
    let activeOut: [String]
    var source = "activeSpeaker"
    if !activeTiles.isEmpty {
        activeOut = activeTiles
    } else if !activeLabels.isEmpty {
        activeOut = activeLabels
    } else {
        activeOut = selectedTiles
        source = "selectedTile"
    }

    return ScanResult(
        zoomPID: app.processIdentifier,
        roster: rosterOut,
        active: deduped(activeOut).filter { !isLocalParticipant($0) },
        activeSource: source,
        latestCaption: latestCaption)
}

// MARK: - AX tree dump

func dumpAXTree() {
    guard AXIsProcessTrusted() else {
        print("dumpAXTree — no Accessibility permission")
        return
    }
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "us.zoom.xos"
    }) else {
        print("dumpAXTree — Zoom not running")
        return
    }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    var count = 0
    let maxDump = 500

    func dump(_ element: AXUIElement, depth: Int) {
        guard count < maxDump else { return }
        let r = axRole(element)
        let desc = axAttr(element, kAXDescriptionAttribute as CFString) ?? ""
        let title = axAttr(element, kAXTitleAttribute as CFString) ?? ""
        let val = axAttr(element, kAXValueAttribute as CFString) ?? ""
        let sel = axIsSelected(element)
        let indent = String(repeating: "  ", count: min(depth, 10))
        if !desc.isEmpty || !title.isEmpty || !val.isEmpty || r != "AXUnknown" {
            var parts = ["role=\(r)"]
            if !desc.isEmpty { parts.append("desc=\(desc.prefix(120))") }
            if !title.isEmpty { parts.append("title=\(title.prefix(80))") }
            if !val.isEmpty { parts.append("val=\(val.prefix(80))") }
            if sel { parts.append("SELECTED") }
            print("AX[\(count)] \(indent)\(parts.joined(separator: " "))")
            count += 1
        }
        for child in axChildren(element) {
            dump(child, depth: depth + 1)
            if count >= maxDump { break }
        }
    }

    print("=== Zoom AX Tree Dump (pid=\(app.processIdentifier)) ===")
    let windows = axAllWindows(root)
    if windows.isEmpty {
        dump(root, depth: 0)
    } else {
        print("(\(windows.count) windows found via kAXWindowsAttribute)")
        for window in windows {
            dump(window, depth: 0)
            if count >= maxDump { break }
        }
    }
    print("=== AX Tree Dump: \(count) elements ===")
}

// MARK: - CLI

struct CLIOptions {
    var json = false
    var dump = false
    var watch = false
    var interval: TimeInterval = 2
}

func parseArgs() -> CLIOptions {
    var opts = CLIOptions()
    let args = CommandLine.arguments.dropFirst()
    for arg in args {
        switch arg {
        case "--json": opts.json = true
        case "--dump": opts.dump = true
        case "--watch": opts.watch = true
        case "--help", "-h":
            print("""
            zoom-info — extract speaker info from Zoom's Accessibility tree

            Usage: zoom-info [options]

            Options:
              --json     Output as JSON instead of pretty text
              --dump     Include the full AX tree dump (first 500 elements)
              --watch    Repeat every 2 seconds until Ctrl-C
              --help     Show this help

            What it reads:
              - Participant roster (all video tiles)
              - Active speaker (tiles marked "active speaker" or selected)
              - Live captions / transcript lines
              - Local participant detection (matches NSFullUserName)

            Requirements:
              - Zoom must be running and in a meeting
              - Terminal needs Accessibility permission
                (System Settings -> Privacy & Security -> Accessibility)
            """)
            exit(0)
        default:
            if let interval = TimeInterval(arg) { opts.interval = interval }
        }
    }
    return opts
}

func runScan(opts: CLIOptions) {
    let scan = zoomScan()
    let trusted = AXIsProcessTrusted()

    if opts.json {
        printJSON(scan: scan, trusted: trusted)
    } else {
        printPretty(scan: scan, trusted: trusted)
    }

    if opts.dump {
        print("\n" + String(repeating: "=", count: 60))
        print("AX TREE DUMP")
        print(String(repeating: "=", count: 60))
        dumpAXTree()
    }
}

func printPretty(scan: ScanResult, trusted: Bool) {
    let timestamp = ISO8601DateFormatter().string(from: .now)
    print("\n[\(timestamp)]")
    print("Accessibility trusted: \(trusted ? "YES" : "NO")")

    if scan.zoomPID == nil {
        print("Zoom: not running or no meeting in progress")
        return
    }

    print("Zoom PID: \(scan.zoomPID!)")
    let rosterStr = scan.roster.isEmpty ? "(empty)" : "[\(scan.roster.joined(separator: ", "))]"
    print("Roster (\(scan.roster.count)): \(rosterStr)")

    if scan.active.isEmpty {
        print("Active speaker: (none detected)")
    } else {
        print("Active speaker: [\(scan.active.joined(separator: ", "))] (source: \(scan.activeSource))")
    }

    if let caption = scan.latestCaption {
        print("Latest caption: \(caption.name): \(caption.text.prefix(80))")
    } else {
        print("Latest caption: (none)")
    }

    let local = scan.roster.filter(isLocalParticipant)
    let remote = scan.roster.filter { !isLocalParticipant($0) }
    print("Local (you): \(local.isEmpty ? "(not found)" : local.joined(separator: ", "))")
    let remoteStr = remote.isEmpty ? "(none)" : "[\(remote.joined(separator: ", "))]"
    print("Remote: \(remoteStr)")
}

func printJSON(scan: ScanResult, trusted: Bool) {
    var obj: [String: Any] = [
        "timestamp": ISO8601DateFormatter().string(from: .now),
        "accessibilityTrusted": trusted,
        "roster": scan.roster,
        "activeSpeakers": scan.active,
        "activeSource": scan.activeSource,
        "localParticipant": scan.roster.filter(isLocalParticipant),
        "remoteParticipants": scan.roster.filter { !isLocalParticipant($0) }
    ]
    if let pid = scan.zoomPID { obj["zoomPID"] = String(pid) }
    if let caption = scan.latestCaption {
        obj["latestCaption"] = ["name": caption.name, "text": caption.text]
    }
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
       let json = String(data: data, encoding: .utf8) {
        print(json)
    }
}

// MARK: - Main

let opts = parseArgs()

if opts.watch {
    while true {
        runScan(opts: opts)
        Thread.sleep(forTimeInterval: opts.interval)
    }
} else {
    runScan(opts: opts)
}
