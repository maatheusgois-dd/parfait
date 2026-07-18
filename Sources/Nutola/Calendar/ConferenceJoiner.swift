import AppKit
import Foundation

/// Opens conference links in the native client when installed, else the web URL.
enum ConferenceJoiner {
    @discardableResult
    static func open(_ url: URL) -> Bool {
        if let deeplink = deeplinkURL(for: url), isNativeAppInstalled(for: url) {
            return openAndLog(url: deeplink, fallback: url)
        }
        return openAndLog(url: url, fallback: nil)
    }

    /// Opens the URL via NSWorkspace and logs a warning when the system can't
    /// launch a handler — a silent `false` return is otherwise indistinguishable
    /// from a missing app or a revoked launch.
    @discardableResult
    private static func openAndLog(url: URL, fallback: URL?) -> Bool {
        let launched = NSWorkspace.shared.open(url)
        if !launched {
            NutolaConsoleLog.app("could not open \(url.absoluteString) via NSWorkspace"
                + (fallback.map { " (tried deeplink; fallback was \($0.absoluteString))" } ?? ""))
        }
        return launched
    }

    /// Whether a native client is registered for this conference provider.
    static func isNativeAppInstalled(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host.contains("zoom") { return appHandles(scheme: "zoommtg") || appInstalled(bundleID: "us.zoom.xos") }
        if host.contains("teams.microsoft") {
            return appHandles(scheme: "msteams") || appInstalled(bundleID: "com.microsoft.teams")
        }
        if host.contains("webex") {
            return appHandles(scheme: "webextel") || appInstalled(bundleID: "com.cisco.webexmeetingsapp")
        }
        if host.contains("meet.google") {
            // Meet registers for https links; no custom deeplink to probe.
            return appHandles(url: url)
        }
        return false
    }

    /// Pure conversion — testable without NSWorkspace.
    static func deeplinkURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        if host.contains("zoom") { return zoomDeeplink(from: url) }
        if host.contains("teams.microsoft") { return teamsDeeplink(from: url) }
        if host.contains("webex") { return webexDeeplink(from: url) }
        return nil
    }

    private static func zoomDeeplink(from url: URL) -> URL? {
        // https://zoom.us/j/123456789?pwd=abc → zoommtg://zoom.us/join?action=join&confno=…&pwd=…
        let parts = url.path.split(separator: "/")
        guard let jIndex = parts.firstIndex(where: { $0 == "j" }),
              jIndex + 1 < parts.count else { return nil }
        let confno = String(parts[jIndex + 1])
        guard !confno.isEmpty, confno.allSatisfy(\.isNumber) else { return nil }

        var components = URLComponents()
        components.scheme = "zoommtg"
        components.host = "zoom.us"
        components.path = "/join"
        var query = [
            URLQueryItem(name: "action", value: "join"),
            URLQueryItem(name: "confno", value: confno),
        ]
        if let pwd = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "pwd" })?.value, !pwd.isEmpty {
            query.append(URLQueryItem(name: "pwd", value: pwd))
        }
        components.queryItems = query
        return components.url
    }

    private static func teamsDeeplink(from url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.scheme = "msteams"
        return components?.url
    }

    private static func webexDeeplink(from url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.scheme = "webextel"
        return components?.url
    }

    private static func appHandles(scheme: String) -> Bool {
        guard let probe = URL(string: "\(scheme)://") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }

    private static func appHandles(url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    private static func appInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}
