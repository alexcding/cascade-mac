import Foundation

struct DocumentLocation: Equatable, Sendable {
    let path: String
    var line: Int = 1
    var column: Int = 1
}

enum WorkspaceLink: Equatable, Sendable {
    case web(URL), file(DocumentLocation)

    static func parse(_ raw: String, directory: String, home: String) -> Self? {
        guard !raw.isEmpty, raw.utf8.count <= 16_384,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if let url = safeWebURL(raw) { return .web(url) }
        var path = raw, line = 1, column = 1
        if raw.lowercased().hasPrefix("file:") {
            guard let url = URLComponents(string: raw), url.scheme?.lowercased() == "file",
                  url.host == nil || url.host == "" || url.host == "localhost",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil else { return nil }
            // Parse literal suffixes before percent-decoding, so %3A12 remains
            // part of a filename rather than unexpectedly becoming a line number.
            let split = splitPosition(url.percentEncodedPath)
            guard let decoded = split.path.removingPercentEncoding, decoded.hasPrefix("/") else { return nil }
            path = decoded; line = split.line; column = split.column
            if let fragment = url.fragment {
                guard let match = fragment.wholeMatch(of: /L([0-9]+)(?:C([0-9]+))?/),
                      let value = Int(match.1) else { return nil }
                line = value
                if let value = match.2 { guard let parsed = Int(value) else { return nil }; column = parsed }
            }
        } else {
            // Never reinterpret an unsupported URI as a path or execute it.
            let split = splitPosition(raw); path = split.path; line = split.line; column = split.column
            if raw.contains("://") || path.firstMatch(of: /^[A-Za-z][A-Za-z0-9+.-]*:/) != nil { return nil }
        }
        guard (1...1_000_000).contains(line), (1...1_000_000).contains(column),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if path.hasPrefix("~/") { path = home + String(path.dropFirst()) }
        else if !path.hasPrefix("/") {
            guard directory.hasPrefix("/"), !path.hasPrefix("~"), !path.isEmpty else { return nil }
            path = (directory as NSString).appendingPathComponent(path)
        }
        return .file(.init(path: (path as NSString).standardizingPath, line: line, column: column))
    }

    private static func splitPosition(_ value: String) -> (path: String, line: Int, column: Int) {
        guard let match = value.wholeMatch(of: /(.+?):([0-9]+)(?::([0-9]+))?/) else {
            return (value, 1, 1)
        }
        return (String(match.1), Int(match.2) ?? 0, match.3.map { Int($0) ?? 0 } ?? 1)
    }
}

enum WorkingFileLocation {
    // Diff messages are scoped to this worktree. Resolve before handing the path
    // to the editor so a symlink cannot intentionally point the view elsewhere.
    static func resolve(_ relative: String, line: Int, root: String) throws -> DocumentLocation {
        guard !relative.isEmpty, relative.utf8.count <= 4096, !relative.hasPrefix("/"),
              !relative.contains("\0"), !relative.split(separator: "/").contains(".."),
              (1...1_000_000).contains(line) else { throw BackendError.operation("Invalid changes-view file location.") }
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
        let file = rootURL.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(rootURL.path == "/" ? "/" : rootURL.path + "/"), file.path != rootURL.path else {
            throw BackendError.operation("This file points outside the worktree. Open it with Open File.")
        }
        return .init(path: file.path, line: line)
    }
}
