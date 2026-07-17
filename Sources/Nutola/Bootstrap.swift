import Foundation

/// One binary, two personalities:
///   Nutola          → the menu bar app
///   Nutola --mcp    → an MCP stdio server over the meeting archive
///   Nutola --version
@main
enum Bootstrap {
    static let version = "0.1.0"

    static func main() {
        // A claude/gh subprocess (or the MCP client) exiting before draining a
        // pipe would otherwise SIGPIPE-kill the whole app mid-recording.
        signal(SIGPIPE, SIG_IGN)
        // Opt-in crash handlers (no-op unless AppSettings.crashDiagnostics is on).
        // Installed before NutolaApp.main() so an early crash is still captured.
        CrashDiagnosticLog.install()
        let args = CommandLine.arguments
        if args.contains("--version") {
            print("nutola \(version)")
            return
        }
        if args.contains("--mcp") {
            MCPServer(archive: MeetingArchive(), templates: TemplateStore()).runBlocking()
            return
        }
        NutolaApp.main()
    }
}
