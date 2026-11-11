import Foundation

/// Decides where links clicked in a terminal open, and finds the local
/// development servers a terminal has printed.
enum GoviLinkRouter {
    /// Loopback web addresses as dev servers print them, e.g.
    /// `http://localhost:3000/`, `http://127.0.0.1:5173`, `http://app.localhost:8080`.
    private static let localPattern = try! NSRegularExpression(
        pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|[A-Za-z0-9-]+\.localhost)(?::\d{2,5})?(?:/[^\s'"<>`)\]]*)?"#,
        options: [.caseInsensitive])

    /// Whether `url` points at this machine over http(s).
    static func isLocalWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host?.lowercased()
        else { return false }
        return ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost")
    }

    /// `0.0.0.0` means "every interface" to a server but isn't a destination;
    /// browse it as localhost. Trailing sentence punctuation is dropped.
    static func browsable(_ url: URL) -> URL {
        var text = url.absoluteString
        while let last = text.last, ".,;:!?".contains(last) { text.removeLast() }
        guard var components = URLComponents(string: text) else { return url }
        if components.host == "0.0.0.0" { components.host = "localhost" }
        return components.url ?? url
    }

    /// `scheme://host:port`, used to reuse a browser pane already showing a server.
    static func origin(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? -1)"
    }

    /// The most recently printed local address in `text`, if any.
    static func latestLocalURL(in text: String) -> URL? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = localPattern.matches(in: text, range: range).last,
            let found = Range(match.range, in: text), let url = URL(string: String(text[found]))
        else { return nil }
        return browsable(url)
    }
}

/// A file named in terminal output, such as `./src/app.ts:42:7`.
struct GoviFileLocation: Equatable {
    var path: String
    var line: Int?
    var column: Int?
}

extension GoviLinkRouter {
    private static let suffixPattern = try! NSRegularExpression(pattern: #"^(.+?)(?::(\d{1,7}))?(?::(\d{1,5}))?:?$"#)

    /// Parses a clicked path or `file:` URL. A trailing `:line` or
    /// `:line:column` is split off, and relative paths are resolved against
    /// `directory`, the terminal's working directory.
    static func fileLocation(_ raw: String, relativeTo directory: String?) -> GoviFileLocation? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("file:") {
            guard let url = URL(string: text), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            text = url.path
        }
        guard !text.isEmpty, !text.contains("\0"), text.utf8.count < 4096 else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = suffixPattern.firstMatch(in: text, range: range), let pathRange = Range(match.range(at: 1), in: text) else { return nil }
        let number = { (index: Int) in Range(match.range(at: index), in: text).flatMap { Int(text[$0]) } }
        var path = String(text[pathRange])
        if !path.hasPrefix("/") {
            guard let directory, directory.hasPrefix("/") else { return nil }
            path = (directory as NSString).appendingPathComponent(path)
        }
        let line = number(2).flatMap { $0 > 0 ? $0 : nil }
        return .init(path: (path as NSString).standardizingPath, line: line, column: line == nil ? nil : number(3))
    }
}

/// Reading files for the editor pane.
enum GoviTextFile {
    static let maxSize = 5 * 1024 * 1024

    /// Text Govi can edit: small enough, no NUL bytes near the start, and UTF-8.
    static func read(_ url: URL) -> Result<String, GoviTextFileError> {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return .failure(.init("\(url.lastPathComponent) isn't a file Govi can open.")) }
        guard (values?.fileSize ?? 0) <= maxSize else {
            return .failure(.init("\(url.lastPathComponent) is larger than \(maxSize / 1024 / 1024) MB, too large for the editor."))
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(.init("Govi couldn't read \(url.lastPathComponent).")) }
        guard !looksBinary(data) else { return .failure(.init("\(url.lastPathComponent) looks like a binary file.")) }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(.init("\(url.lastPathComponent) isn't UTF-8 text, so the editor can't open it safely."))
        }
        return .success(text)
    }

    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }

    /// Whether a clicked path should open in the editor rather than with macOS.
    static func isEditable(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
            (values.fileSize ?? 0) <= maxSize, let handle = try? FileHandle(forReadingFrom: url)
        else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        return !looksBinary(head)
    }
}

struct GoviTextFileError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Quick Look targets

extension GoviLinkRouter {
    /// What Quick Look can show for a piece of terminal text: a web page, or a
    /// file or folder that exists. Bare words only count when they look like a
    /// file name, so ordinary output isn't mistaken for paths.
    static func previewTarget(_ raw: String, relativeTo directory: String?) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, "\"'`(<[{".contains(first) { text.removeFirst() }
        while let last = text.last, "\"'`)>]}.,;!?".contains(last) { text.removeLast() }
        guard !text.isEmpty, text.utf8.count < 4096 else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: text), url.host?.isEmpty == false else { return nil }
            return browsable(url)
        }
        if text.hasPrefix("~/") { text = (text as NSString).expandingTildeInPath }
        guard text.contains("/") || text.contains("."), let location = fileLocation(text, relativeTo: directory), location.path != "/"
        else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue, !text.contains("/") { return nil }
        return URL(fileURLWithPath: location.path)
    }

    /// Every previewable link in `text`, oldest first and without repeats. Only
    /// the most recent output is searched, so a long scrollback stays cheap.
    static func previewTargets(in text: String, relativeTo directory: String?, limit: Int = 100, maxWords: Int = 6000) -> [URL] {
        var found: [URL] = []
        var seen = Set<URL>()
        var examined = 0
        for word in text.split(whereSeparator: { $0.isWhitespace }).reversed() {
            guard word.contains("/") || word.contains(".") else { continue }
            examined += 1
            if examined > maxWords || found.count >= limit { break }
            if let url = previewTarget(String(word), relativeTo: directory), seen.insert(url).inserted { found.append(url) }
        }
        return found.reversed()
    }

    /// The whitespace-delimited run of `line` at `column` (one character per
    /// terminal cell). `word` is the terminal's own word under the pointer; it
    /// settles the answer when wide characters shift the columns.
    static func token(in line: String, atColumn column: Int, containing word: String) -> String? {
        var tokens: [(text: String, range: Range<Int>)] = []
        var current = "", start = 0, count = 0
        for character in line {
            if character.isWhitespace || character == "\0" {
                if !current.isEmpty { tokens.append((current, start..<count)) }
                current = ""
            } else {
                if current.isEmpty { start = count }
                current.append(character)
            }
            count += 1
        }
        if !current.isEmpty { tokens.append((current, start..<count)) }
        if let hit = tokens.first(where: { $0.range.contains(column) && $0.text.contains(word) }) { return hit.text }
        return tokens.first { $0.text.contains(word) }?.text
    }
}
