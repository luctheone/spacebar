import Foundation

/// Eligibility for a user-confirmed native move to Trash. This performs no move,
/// deletion or content read. The caller still handles native-operation failures.
public enum StorageTrashPolicy {
    private static let protectedContainers = [
        "", "/Desktop", "/Documents", "/Downloads", "/Library", "/Pictures", "/Movies", "/Music",
        "/Library/Application Support", "/Library/Caches", "/.Trash",
    ]

    public static func allows(_ url: URL, home: URL) -> Bool {
        guard localFileURL(url), localFileURL(home) else { return false }
        // standardizedFileURL can rewrite an existing /private/tmp parent to
        // /tmp while leaving a nonexistent descendant unchanged. Normalize
        // components lexically first, without filesystem-dependent aliases.
        let candidate = URL(fileURLWithPath: lexicalPath(url))
        let root = URL(fileURLWithPath: lexicalPath(home), isDirectory: true)
        guard root.path != "/", eligible(candidate.path, under: root.path) else { return false }

        let canonicalHome = lexicalPath(root.resolvingSymlinksInPath())
        // Follow only parent directories. A final symlink is the object moved
        // by Trash, so its outside/protected destination must not replace it.
        let canonicalCandidate = lexicalPath(url.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent))
        return canonicalHome != "/" && eligible(canonicalCandidate, under: canonicalHome)
    }

    private static func localFileURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost") &&
            url.query == nil && url.fragment == nil
    }

    private static func lexicalPath(_ url: URL) -> String {
        var components: [Substring] = []
        for component in url.path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(component) }
        }
        return "/" + components.joined(separator: "/")
    }

    private static func eligible(_ path: String, under home: String) -> Bool {
        path.hasPrefix(home + "/") &&
            !protectedContainers.contains(where: { path == home + $0 }) &&
            !path.hasPrefix(home + "/.Trash/")
    }
}
