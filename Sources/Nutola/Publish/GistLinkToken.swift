import Foundation

/// Packs a gist's (user, id, commit SHA) into one opaque, reversible base64url
/// token so a published link is just `notes.nutola.to/<token>` — the GitHub
/// username, gist id, and raw-CDN path shape never appear in the URL, and it's
/// shorter than spelling them out. This is cosmetic obfuscation (trivially
/// reversible), not a secret: its only job is to keep the gist plumbing out of
/// the address bar. The notes.nutola.to Worker (workers/notes-proxy) decodes
/// it back to the raw-URL coordinates before fetching upstream.
///
/// Byte layout, then base64url with no padding:
///   [1 byte: user UTF-8 length N][N bytes: user][gist-id bytes][20 bytes: SHA]
/// The commit SHA is a fixed 40 hex chars → the trailing 20 bytes, so the gist
/// id (variable 20–32 hex → 10–16 bytes) is everything between the username and
/// the SHA and needs no length prefix of its own. The filename is dropped since
/// Nutola always publishes `meeting.html`; the Worker reattaches it.
enum GistLinkToken {
    /// The gist filename Nutola always publishes; constant, so it's dropped from
    /// the token and reattached by the Worker.
    static let filename = "meeting.html"

    static func encode(user: String, gistID: String, sha: String) -> String? {
        let userBytes = Array(user.utf8)
        guard (1...255).contains(userBytes.count),
              let gistBytes = hexToBytes(gistID), !gistBytes.isEmpty,
              let shaBytes = hexToBytes(sha), shaBytes.count == 20
        else { return nil }
        var bytes: [UInt8] = [UInt8(userBytes.count)]
        bytes.append(contentsOf: userBytes)
        bytes.append(contentsOf: gistBytes)
        bytes.append(contentsOf: shaBytes)
        return base64URLEncode(Data(bytes))
    }

    struct Decoded: Equatable {
        let user: String
        let gistID: String
        let sha: String
    }

    static func decode(_ token: String) -> Decoded? {
        guard let data = base64URLDecode(token) else { return nil }
        let bytes = [UInt8](data)
        guard let userLen = bytes.first.map(Int.init), userLen >= 1,
              bytes.count >= 1 + userLen + 20 + 1  // +1 gist byte minimum
        else { return nil }
        guard let user = String(bytes: bytes[1 ..< 1 + userLen], encoding: .utf8) else { return nil }
        let rest = bytes[(1 + userLen)...]
        let gistBytes = rest.dropLast(20)
        let shaBytes = rest.suffix(20)
        return Decoded(user: user, gistID: bytesToHex(gistBytes), sha: bytesToHex(shaBytes))
    }

    // MARK: - hex + base64url helpers

    static func hexToBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i ..< j], radix: 16) else { return nil }
            out.append(byte)
            i = j
        }
        return out
    }

    static func bytesToHex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ token: String) -> Data? {
        var b64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = b64.count % 4
        if remainder == 1 { return nil }  // never a valid base64 length
        if remainder != 0 { b64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: b64)
    }
}
