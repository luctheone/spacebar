import Foundation
import SpaceBarCore

private func trashFixture() throws -> (root: URL, home: URL, outside: URL) {
    let root = try fixture()
    let home = root.appendingPathComponent("home"), outside = root.appendingPathComponent("outside")
    for directory in [home, outside, home.appendingPathComponent("Documents"),
                      home.appendingPathComponent("Downloads"), home.appendingPathComponent("Library/Application Support"),
                      home.appendingPathComponent("Library/Caches"), home.appendingPathComponent(".Trash"),
                      home.appendingPathComponent(".Trash-other"),
                      home.appendingPathComponent("temp")] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return (root,home,outside)
}

let trashChecks: [(String, () throws -> Void)] = [
    ("Trash eligibility allows home contents but protects containing roots", {
        let f = try trashFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for relative in ["Downloads/archive.zip", "Documents/draft.txt", "Library/Caches/vendor", "Library/Application Support/unused-tool", ".Trash-other/item"] {
            try expect(StorageTrashPolicy.allows(f.home.appendingPathComponent(relative),home:f.home), "Ordinary home descendant rejected: \(relative)")
        }
        for relative in ["", "Desktop", "Documents", "Downloads", "Library", "Pictures", "Movies", "Music", "Library/Application Support", "Library/Caches", ".Trash", ".Trash/item"] {
            let item = relative.isEmpty ? f.home : f.home.appendingPathComponent(relative)
            try expect(!StorageTrashPolicy.allows(item,home:f.home), "Protected container/Trash allowed: \(relative)")
        }
    }),
    ("Trash eligibility rejects system roots, sibling homes and remote URLs", {
        let f = try trashFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for item in [URL(fileURLWithPath:"/"),URL(fileURLWithPath:"/System"),URL(fileURLWithPath:"/Library"),
                     f.outside.appendingPathComponent("item"),f.root.appendingPathComponent("home-other/item"),
                     URL(string:"https://example.com/file")!,URL(string:"file://server\(f.home.path)/item")!] {
            try expect(!StorageTrashPolicy.allows(item,home:f.home), "Outside/locality boundary was bypassed")
        }
        try expect(!StorageTrashPolicy.allows(URL(fileURLWithPath:"/tmp/item"),home:URL(fileURLWithPath:"/")), "Filesystem root became a valid home boundary")
    }),
    ("Trash eligibility rejects escape through a symlinked parent", {
        let f = try trashFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let escape = f.home.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at:escape,withDestinationURL:f.outside)
        try expect(!StorageTrashPolicy.allows(escape.appendingPathComponent("item"),home:f.home), "Canonical parent escaped home")
        try expect(StorageTrashPolicy.allows(escape,home:f.home), "Moving the final symlink itself was incorrectly treated as moving its destination")
    }),
    ("Trash eligibility protects roots reached through aliases to home", {
        let f = try trashFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let alias = f.home.appendingPathComponent("home-alias")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:f.home)
        for relative in ["Documents", "Library", "Library/Application Support", ".Trash", ".Trash/item"] {
            try expect(!StorageTrashPolicy.allows(alias.appendingPathComponent(relative),home:f.home), "Canonical protected root allowed through alias: \(relative)")
        }
        try expect(StorageTrashPolicy.allows(alias.appendingPathComponent("Documents/draft"),home:f.home), "Ordinary canonical descendant was rejected")
        let documentsLink = f.home.appendingPathComponent("documents-link")
        try FileManager.default.createSymbolicLink(at:documentsLink,withDestinationURL:f.home.appendingPathComponent("Documents"))
        try expect(StorageTrashPolicy.allows(documentsLink,home:f.home), "A final link to a protected directory should move only the link")
    }),
    ("Trash eligibility normalizes traversal before testing protected boundaries", {
        let f = try trashFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try expect(StorageTrashPolicy.allows(URL(fileURLWithPath:f.home.path+"/temp/../Documents/draft"),home:f.home), "Safe normalized descendant rejected")
        try expect(!StorageTrashPolicy.allows(URL(fileURLWithPath:f.home.path+"/temp/../Documents"),home:f.home), "Traversal reached a protected root")
        try expect(!StorageTrashPolicy.allows(URL(fileURLWithPath:f.home.path+"/temp/../../outside/item"),home:f.home), "Traversal escaped home")
    }),
    ("Trash eligibility resolves symlink-plus-parent traversal before canonical boundary checks", {
        let f = try trashFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let deep = f.outside.appendingPathComponent("deep")
        try FileManager.default.createDirectory(at:deep,withIntermediateDirectories:true)
        let link = f.home.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:deep)
        let ambiguous = URL(fileURLWithPath:f.home.path+"/outside-link/../item")
        try expect(!StorageTrashPolicy.allows(ambiguous,home:f.home), "Lexical normalization hid a symlink-plus-.. escape")
    }),
    ("Trash eligibility supports a symlinked home without widening its boundary", {
        let f = try trashFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let homeAlias = f.root.appendingPathComponent("home-location")
        try FileManager.default.createSymbolicLink(at:homeAlias,withDestinationURL:f.home)
        try expect(StorageTrashPolicy.allows(homeAlias.appendingPathComponent("Documents/draft"),home:homeAlias), "Canonical home alias rejected its own contents")
        try expect(!StorageTrashPolicy.allows(homeAlias.appendingPathComponent("Documents"),home:homeAlias), "Canonical home alias lost root protection")
        try expect(!StorageTrashPolicy.allows(f.outside.appendingPathComponent("item"),home:homeAlias), "Home alias admitted another directory")
    }),
]
