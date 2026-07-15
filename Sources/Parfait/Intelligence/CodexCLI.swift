import AppKit
import Foundation

enum CodexCLIError: LocalizedError {
    case notInstalled
    case notLoggedIn
    case failed(status: Int32, stderr: String)
    case badOutput

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Codex CLI not found. Install it from chatgpt.com/codex."
        case .notLoggedIn:
            return "Codex is not signed in. Run `codex login` in Terminal once."
        case .failed(let status, let stderr):
            return stderr.isEmpty
                ? "Codex exited with status \(status)."
                : "Codex failed (status \(status)): \(stderr)"
        case .badOutput:
            return "Codex returned unexpected output."
        }
    }
}

struct CodexCLI {
    struct RunResult: Sendable {
        let text: String
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedResolution: URL??

    private static func fastProbe() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/codex",
            "\(home)/.codex/packages/standalone/current/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // npm/nvm installs — common on dev Macs, invisible to a bare GUI PATH.
        let nvmBase = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
            for version in versions.sorted().reversed() {
                let path = "\(nvmBase)/\(version)/bin/codex"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }

    private static func shellProbe() -> URL? {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        sh.arguments = ["-lc", "command -v codex"]
        let pipe = Pipe()
        sh.standardOutput = pipe
        sh.standardError = FileHandle.nullDevice
        guard (try? sh.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        sh.waitUntilExit()
        guard sh.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func resolveBlocking() -> URL? {
        cacheLock.lock()
        if let cached = cachedResolution {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let found = fastProbe() ?? shellProbe()
        cacheLock.lock()
        cachedResolution = .some(found)
        cacheLock.unlock()
        return found
    }

    static var isInstalled: Bool {
        cacheLock.lock()
        let cached = cachedResolution
        cacheLock.unlock()
        if let cached { return cached != nil }
        if fastProbe() != nil { return true }
        // Auth on disk means Codex is set up even before the shell probe warms.
        return authFromDisk()
    }

    static var isReady: Bool { isInstalled && isLoggedIn() }

    static var workDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Parfait/codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func codexHome() -> URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    static func authFromDisk() -> Bool {
        let url = codexHome().appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any]
        else { return false }
        let access = (tokens["access_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !access.isEmpty
    }

    static func isLoggedIn() -> Bool {
        if authFromDisk() { return true }
        guard let cli = resolveBlocking() else { return false }
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        sh.arguments = ["-lc", "\"\(cli.path)\" login status"]
        sh.standardInput = FileHandle.nullDevice
        sh.standardError = FileHandle.nullDevice
        let out = Pipe()
        sh.standardOutput = out
        guard (try? sh.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        sh.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sh.terminationStatus == 0
            && !text.localizedCaseInsensitiveContains("not logged in")
            && !text.isEmpty
    }

    static func openLogin() {
        if let cli = resolveBlocking() {
            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
            sh.arguments = ["-lc", "\"\(cli.path)\" login"]
            try? sh.run()
            return
        }
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex")!)
    }

    /// Non-interactive run via `codex exec`. Runs through a login shell so nvm/npm
    /// wrappers get `node` on PATH — a bare Process() launch fails in GUI apps.
    static func run(
        prompt: String,
        stdin: String? = nil,
        systemPrompt: String? = nil
    ) async throws -> RunResult {
        guard isReady else {
            throw isLoggedIn() ? CodexCLIError.notInstalled : CodexCLIError.notLoggedIn
        }

        let outFile = workDir.appendingPathComponent("last-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: outFile) }

        var fullPrompt = prompt
        if let systemPrompt {
            fullPrompt = "\(systemPrompt)\n\n\(prompt)"
        }

        let cmd = """
        cd \(shellQuote(workDir.path)) && codex exec -s read-only --ephemeral --skip-git-repo-check --output-last-message \(shellQuote(outFile.path)) \(shellQuote(fullPrompt))
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", cmd]

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        async let stderrData = readToEnd(stderrPipe.fileHandleForReading)

        let stdinData = stdin.map { Data($0.utf8) }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                try? stderrPipe.fileHandleForWriting.close()
                continuation.resume(throwing: CodexCLIError.failed(status: -1, stderr: error.localizedDescription))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let writer = stdinPipe.fileHandleForWriting
                if let stdinData { try? writer.write(contentsOf: stdinData) }
                try? writer.close()
            }
        }

        let err = await stderrData
        guard status == 0 else {
            throw CodexCLIError.failed(status: status, stderr: tail(String(decoding: err, as: UTF8.self)))
        }
        let text = (try? String(contentsOf: outFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw CodexCLIError.badOutput }
        return RunResult(text: text)
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }

    private static func tail(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(2000))
    }
}
