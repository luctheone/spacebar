import Foundation
import Darwin

/// Measures allocated blocks without opening regular-file data. Scans are manual and never delete.
/// The explicitly selected root's ancestors are resolved by macOS; descendants are accessed
/// relative to held directory descriptors and never followed through a symbolic link.
public final class FolderScanner: Sendable {
    private let timeLimit: TimeInterval
    private let maximumDepth = 64
    public init(timeLimit: TimeInterval = 120) { self.timeLimit = max(0, timeLimit) }

    public func scan(url: URL, cancelled: () -> Bool = { false },
                     progress: ((Int, URL) -> Void)? = nil) -> FolderScanResult {
        let root = url.absoluteURL
        let started = Date()
        var rootStat = stat()
        var rows: [FolderUsage] = []
        var seen = Set<FileIdentity>()
        var scanned = 0
        var denied = 0
        var links = 0
        var clouds = 0
        var mounts = 0
        var cancellation = false
        var timedOut = false
        var lastProgress = Date.distantPast
        // Checked between metadata/directory reads; a blocked kernel call itself is not preempted.
        func shouldStop() -> Bool {
            if cancelled() { cancellation = true; return true }
            if Date().timeIntervalSince(started) >= timeLimit { timedOut = true; return true }
            return false
        }
        func finish() -> FolderScanResult {
            FolderScanResult(rootURL: root, rows: rows.sorted {
                $0.allocatedBytes == $1.allocatedBytes ? $0.name < $1.name : $0.allocatedBytes > $1.allocatedBytes
            }, scannedFiles: scanned, deniedCount: denied, skippedSymlinks: links,
                             skippedCloudPlaceholders: clouds, skippedMounts: mounts,
                             wasCancelled: cancellation, wasTimeLimited: timedOut, date: Date())
        }
        func unreadable(_ totals: inout ScanTotals) {
            denied += 1; totals.denied += 1; totals.partial = true
        }
        func publishProgress(_ entry: URL) {
            if Date().timeIntervalSince(lastProgress) > 0.25 {
                progress?(scanned, entry); lastProgress = Date()
            }
        }
        func walk(parentFD: Int32, name: String, entry: URL, depth: Int, totals: inout ScanTotals) {
            if shouldStop() { totals.partial = true; return }
            var info = stat()
            guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { unreadable(&totals); return }
            let type = info.st_mode & S_IFMT
            if depth == 1 { totals.isDirectory = type == S_IFDIR }
            if type == S_IFLNK { links += 1; return }
            if info.st_dev != rootStat.st_dev { mounts += 1; totals.partial = true; return }
            if info.st_flags & UInt32(SF_DATALESS) != 0 { clouds += 1; return }
            guard type == S_IFREG || type == S_IFDIR else { return }
            let identity = FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
            guard seen.insert(identity).inserted else { return }
            totals.bytes += UInt64(max(0, info.st_blocks)) * 512
            totals.apparent += UInt64(max(0, info.st_size))
            if info.st_nlink > 1 { totals.sharedFiles += 1 }
            scanned += 1
            publishProgress(entry)
            guard type == S_IFDIR else { return }
            if shouldStop() { totals.partial = true; return }
            // A bounded ancestor stack also bounds held descriptors. Deeper coverage is explicit.
            guard depth < maximumDepth else { unreadable(&totals); return }
            let descriptor = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                let openError = errno
                var changed = stat()
                if openError == ELOOP || (fstatat(parentFD, name, &changed, AT_SYMLINK_NOFOLLOW) == 0 && changed.st_mode & S_IFMT == S_IFLNK) {
                    links += 1
                }
                unreadable(&totals); return
            }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
                close(descriptor); unreadable(&totals); return
            }
            // Recheck the held object after opening, before reading any directory entries.
            guard opened.st_flags & UInt32(SF_DATALESS) == 0 else {
                clouds += 1; close(descriptor); return
            }
            guard let directory = fdopendir(descriptor) else {
                close(descriptor); unreadable(&totals); return
            }
            defer { closedir(directory) } // fdopendir owns descriptor on success.
            while !shouldStop() {
                errno = 0
                let next = readdir(directory)
                let readError = errno
                if shouldStop() { totals.partial = true; return }
                guard let next else {
                    if readError != 0 { unreadable(&totals) }
                    return
                }
                let childName = directoryEntryName(next)
                if childName == "." || childName == ".." { continue }
                walk(parentFD: dirfd(directory), name: childName,
                     entry: entry.appendingPathComponent(childName), depth: depth + 1, totals: &totals)
                if cancellation || timedOut { totals.partial = true; return }
            }
            totals.partial = true
        }

        if shouldStop() { return finish() }
        guard root.isFileURL, lstat(root.path, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            denied = 1; return finish()
        }
        guard rootStat.st_flags & UInt32(SF_DATALESS) == 0 else { clouds = 1; return finish() }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { denied = 1; return finish() }
        var openedRoot = stat()
        guard fstat(rootFD, &openedRoot) == 0,
              openedRoot.st_dev == rootStat.st_dev, openedRoot.st_ino == rootStat.st_ino else {
            close(rootFD); denied = 1; return finish()
        }
        guard openedRoot.st_flags & UInt32(SF_DATALESS) == 0 else {
            close(rootFD); clouds = 1; return finish()
        }
        guard let directory = fdopendir(rootFD) else { close(rootFD); denied = 1; return finish() }
        defer { closedir(directory) }
        while !shouldStop() {
            errno = 0
            let next = readdir(directory)
            let readError = errno
            if shouldStop() { break }
            guard let next else {
                if readError != 0 { denied += 1 }
                break
            }
            let name = directoryEntryName(next)
            if name == "." || name == ".." { continue }
            let child = root.appendingPathComponent(name)
            var totals = ScanTotals()
            walk(parentFD: dirfd(directory), name: name, entry: child, depth: 1, totals: &totals)
            rows.append(FolderUsage(url: child, allocatedBytes: totals.bytes, apparentBytes: totals.apparent,
                                    sharedBlockFiles: totals.sharedFiles, isDirectory: totals.isDirectory,
                                    deniedCount: totals.denied, isPartial: totals.partial))
            if cancellation || timedOut { break }
        }
        return finish()
    }
}

private struct ScanTotals {
    var bytes: UInt64 = 0
    var apparent: UInt64 = 0
    var sharedFiles = 0
    var denied = 0
    var partial = false
    var isDirectory = false
}

private struct FileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
}

private func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
    let capacity = Int(entry.pointee.d_namlen) + 1
    return withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
    }
}
