import Foundation

/// Directories and files only this user can touch: dirs 0700, files 0600, owned by
/// us, never a symlink. Used for everything the app keeps under ~/.crossagent and to vet a file before trusting what is in it.
enum PrivateFiles {
    /// Why a path was refused.
    enum Problem: Error, Equatable {
        case missing, symlink, notOwned, sharedWritable, wrongType
    }

    /// Checks a path without following a final symlink: it must exist, be a directory
    /// (or a regular file), belong to this user and not be group or other writable.
    static func check(_ path: String, directory: Bool, uid: uid_t = getuid()) -> Problem? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .missing }
        let kind = st.st_mode & S_IFMT
        if kind == S_IFLNK { return .symlink }
        if kind != (directory ? S_IFDIR : S_IFREG) { return .wrongType }
        if st.st_uid != uid { return .notOwned }
        if st.st_mode & (S_IWGRP | S_IWOTH) != 0 { return .sharedWritable }
        return nil
    }

    /// True if `path` is a file we can trust: see `check`.
    static func isTrusted(file path: String) -> Bool { check(path, directory: false) == nil }

    /// Makes `url` (and missing parents) as 0700 and tightens it to 0700 if it was
    /// looser. Refuses a symlink or a dir someone else owns. Parents that already
    /// exist are left alone, except ones we create.
    @discardableResult
    static func ensureDir(_ url: URL) -> Problem? {
        let path = url.path
        if check(path, directory: true) == .missing {
            let parent = url.deletingLastPathComponent()
            if parent.path != path, check(parent.path, directory: true) == .missing { ensureDir(parent) }
            if mkdir(path, 0o700) != 0 && errno != EEXIST { return .missing }
        }
        switch check(path, directory: true) {
        case nil, .sharedWritable?: break
        case let p?: return p
        }
        var st = stat()
        if lstat(path, &st) == 0, st.st_mode & 0o777 != 0o700, chmod(path, 0o700) != 0 { return .sharedWritable }
        return nil
    }

    /// Writes `data` to `url` as 0600 through a temp file and a rename, so a reader never
    /// sees half a file and a symlink planted at the name is replaced, not followed.
    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        var tmpl = Array(dir.appendingPathComponent(".\(url.lastPathComponent).XXXXXX").path.utf8CString)
        let fd = mkstemp(&tmpl)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let tmp = String(cString: tmpl)
        let ok = fchmod(fd, 0o600) == 0 && data.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        close(fd)
        guard ok, rename(tmp, url.path) == 0 else {
            unlink(tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// At launch: ~/.crossagent and its ssh dir made private (see `SSH.prepare`), and
    /// the events, approvals and bin dirs the hook and skill make tightened to 0700
    /// if they exist and are ours.
    static func prepareAtLaunch() {
        SSH.prepare()
        for name in ["events", "approvals", "bin"] {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            switch check(dir.path, directory: true) {
            case nil, .sharedWritable?: ensureDir(dir)
            case .missing?: break
            case let p?: NSLog("CrossAgent: %@ is not a private dir of ours (%@)", dir.path, "\(p)")
            }
        }
    }

    /// ~/.crossagent, the root for events, approvals, bin and ssh.
    static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".crossagent", isDirectory: true)
    }

}
