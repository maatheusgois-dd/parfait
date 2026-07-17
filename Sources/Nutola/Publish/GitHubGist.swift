import Foundation

enum GistError: LocalizedError {
    case ghMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .ghMissing:
            return "GitHub CLI not found. Install it (brew install gh) and run gh auth login."
        case .failed(let message):
            return message
        }
    }
}

enum GitHubGist {
    static func discover() -> URL? {
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Login shell picks up PATH additions (mise, custom prefixes) that a
        // menu-bar app's environment doesn't inherit.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v gh"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let path = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    static var isAvailable: Bool { discover() != nil }

    /// Derives the shareable notes.nutola.to link from a gist's raw URL. The raw
    /// URL's (user, gist id, commit SHA) are packed into one opaque base64url token
    /// (see GistLinkToken) so the published link is just notes.nutola.to/<token> —
    /// the GitHub username and gist path never appear. The Worker decodes the token
    /// before fetching upstream. Returns nil unless the input is the expected
    /// gist.githubusercontent.com raw-URL shape.
    static func renderedURL(fromRaw raw: String) -> URL? {
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = rawGistURLPattern.firstMatch(in: raw, range: range),
              let userRange = Range(match.range(at: 1), in: raw),
              let gistRange = Range(match.range(at: 2), in: raw),
              let shaRange = Range(match.range(at: 3), in: raw),
              let token = GistLinkToken.encode(
                  user: String(raw[userRange]),
                  gistID: String(raw[gistRange]),
                  sha: String(raw[shaRange]))
        else { return nil }
        return URL(string: "https://notes.nutola.to/\(token)")
    }

    private static let rawGistURLPattern = try! NSRegularExpression(
        pattern: #"^https://gist\.githubusercontent\.com/([A-Za-z0-9-]{1,39})/([0-9a-f]{20,32})/raw/([0-9a-f]{40})/[^/]+$"#)

    /// Creates a secret gist — unlisted, NOT private: anyone with the link can read it —
    /// and derives a rendered-HTML URL by host-swapping the commit-SHA-pinned raw URL
    /// (see `renderedURL(fromRaw:host:)`).
    static func publish(
        html: String, filename: String, description: String
    ) async throws -> (gist: URL, rendered: URL) {
        guard let gh = discover() else { throw GistError.ghMissing }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-gist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The gist filename comes from the file on disk, so it must carry the real name.
        let file = dir.appendingPathComponent(filename)
        try html.data(using: .utf8)!.write(to: file, options: .atomic)

        // gh prints progress to stderr and only the gist URL to stdout.
        let created = try await run(gh, ["gist", "create", file.path, "--desc", description])
        guard let line = created.split(whereSeparator: \.isNewline).last,
              let gistURL = URL(string: line.trimmingCharacters(in: .whitespaces)),
              gistURL.scheme?.hasPrefix("http") == true
        else { throw GistError.failed("Unexpected gh gist create output: \(created)") }

        let id = gistURL.lastPathComponent
        let raw = try await run(gh, ["api", "gists/\(id)", "--jq", ".files[\"\(filename)\"].raw_url"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rendered = renderedURL(fromRaw: raw)
        else { throw GistError.failed("Could not resolve raw URL for gist \(id)") }
        return (gist: gistURL, rendered: rendered)
    }

    private static func readAll(_ handle: FileHandle) async -> Data {
        var data = Data()
        do {
            for try await byte in handle.bytes { data.append(byte) }
        } catch {}
        return data
    }

    private static func run(_ tool: URL, _ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes while the process runs; a full pipe buffer would deadlock gh.
        async let stdout = readAll(outPipe.fileHandleForReading)
        async let stderr = readAll(errPipe.fileHandleForReading)

        let status: Int32
        do {
            status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            // Never launched: close our write ends so the readers see EOF and unwind.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            throw error
        }

        let out = String(data: await stdout, encoding: .utf8) ?? ""
        guard status == 0 else {
            let err = String(data: await stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw GistError.failed(err.isEmpty ? "gh exited with status \(status)" : err)
        }
        return out
    }
}
