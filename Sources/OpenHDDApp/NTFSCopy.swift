#if OPENHDD_LOCAL
import AppKit
import Darwin
import Foundation

/// One file of a copy: where it comes from and where it goes on the volume.
struct CopyEntry {
    let source: URL
    /// Folder on the volume, relative to its root; "" for the root.
    let folder: String
    let name: String
    let size: UInt64
    var replace = false

    var path: String { folder.isEmpty ? name : folder + "/" + name }
}

/// What the user asked to copy onto one NTFS partition.
struct CopyPlan {
    let partition: String
    let volumeName: String
    var entries: [CopyEntry]
    /// Folders to create (or merge with existing ones), parents first.
    var folders: [String]
    /// Existing folder chosen as destination, relative to the root; "" for the root.
    let destination: String

    var totalBytes: UInt64 { entries.reduce(0) { $0 + $1.size } }
    var replacedCount: Int { entries.filter(\.replace).count }
    var destinationLabel: String { destination.isEmpty ? L("root folder") : L("folder “\(destination)”") }
    /// Names shown while copying, relative to the destination.
    var names: [String] {
        entries.map { entry in
            destination.isEmpty ? entry.path : String(entry.path.dropFirst(destination.count + 1))
        }
    }

    /// The tool's manifest: NUL-separated "D" folder and "F" source, folder,
    /// name, replace records. Written 0600 in the user's temporary folder.
    func writeManifest() -> URL? {
        var data = Data()
        func add(_ fields: String...) {
            for field in fields { data.append(contentsOf: Array(field.utf8)); data.append(0) }
        }
        for folder in folders { add("D", folder) }
        for entry in entries { add("F", entry.source.path, entry.folder, entry.name, entry.replace ? "1" : "0") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openhdd-manifest-\(UUID().uuidString)")
        return FileManager.default.createFile(atPath: url.path, contents: data,
                                              attributes: [.posixPermissions: 0o600]) ? url : nil
    }
}

/// Lets the user stop a long walk through folders.
final class ScanToken: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func cancel() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

/// What a walk through the chosen files and folders found.
struct CopyScan {
    var cancelled = false
    var entries: [CopyEntry] = []
    var folders: [String] = []
    var problems: [String] = []
    /// Symbolic links and special files, which are not copied.
    var skipped: [String] = []
    /// Indexes of entries whose name already exists as a file on the volume.
    var existing: [Int] = []
}

enum CopyScanner {
    /// Finder bookkeeping that means nothing on Windows.
    static func ignored(_ name: String) -> Bool {
        name == ".DS_Store" || name == ".localized" || name.hasPrefix("._")
    }

    private static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : name.isEmpty ? folder : folder + "/" + name
    }

    private static func fold(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: nil)
    }

    /// Walks the sources (files and whole folders) without following
    /// symbolic links, and maps them into `destination` on the volume.
    static func scan(_ sources: [URL], into destination: String, token: ScanToken? = nil,
                     progress: ((Int, UInt64) -> Void)? = nil) -> CopyScan {
        var scan = CopyScan()
        var bytes: UInt64 = 0
        func counted() -> Bool {
            if scan.entries.count % 250 == 0 { progress?(scan.entries.count, bytes) }
            if token?.isCancelled == true { scan.cancelled = true; return false }
            return true
        }
        var names: [String: Set<String>] = [:]
        func claim(_ folder: String, _ name: String) -> Bool {
            if names[folder, default: []].insert(fold(name)).inserted { return true }
            scan.problems.append(L("“\(join(folder, name))”: name already used in the same folder (Windows ignores letter case)"))
            return false
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        for url in sources {
            let name = NTFSCopyRunner.normalized(url.lastPathComponent)
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { scan.skipped.append(name); continue }
            if let problem = NTFSCopyRunner.problem(withName: name) {
                scan.problems.append("«\(name)»: \(problem)")
                continue
            }
            if values?.isRegularFile == true {
                if claim(destination, name) {
                    scan.entries.append(CopyEntry(source: url, folder: destination, name: name,
                                                  size: UInt64(values?.fileSize ?? 0)))
                    bytes += UInt64(values?.fileSize ?? 0)
                }
                continue
            }
            guard values?.isDirectory == true else { scan.skipped.append(name); continue }
            guard claim(destination, name) else { continue }
            let top = join(destination, name)
            scan.folders.append(top)
            var unreadable: [String] = []
            guard let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys, options: [],
                errorHandler: { failed, _ in unreadable.append(failed.lastPathComponent); return true })
            else { scan.problems.append(L("“\(name)”: folder unreadable")); continue }
            for case let fileURL as URL in walker {
                if token?.isCancelled == true { scan.cancelled = true; return scan }
                // The walk's depth, not string prefixes: the enumerator may
                // hand back resolved paths (/private/var for /var).
                let relative = fileURL.pathComponents.suffix(walker.level)
                    .map { NTFSCopyRunner.normalized($0) }
                guard let leaf = relative.last else { continue }
                let folder = join(top, relative.dropLast().joined(separator: "/"))
                let shown = join(name, relative.joined(separator: "/"))
                let info = try? fileURL.resourceValues(forKeys: Set(keys))
                let isDirectory = info?.isDirectory == true && info?.isSymbolicLink != true
                if ignored(leaf) { if isDirectory { walker.skipDescendants() }; continue }
                if info?.isSymbolicLink == true { scan.skipped.append(shown); continue }
                if let problem = NTFSCopyRunner.problem(withName: leaf) {
                    scan.problems.append("«\(shown)»: \(problem)")
                    if isDirectory { walker.skipDescendants() }
                    continue
                }
                if isDirectory {
                    if claim(folder, leaf) { scan.folders.append(join(folder, leaf)) }
                    else { walker.skipDescendants() }
                } else if info?.isRegularFile == true {
                    if claim(folder, leaf) {
                        scan.entries.append(CopyEntry(source: fileURL, folder: folder, name: leaf,
                                                      size: UInt64(info?.fileSize ?? 0)))
                        bytes += UInt64(info?.fileSize ?? 0)
                        if !counted() { return scan }
                    }
                } else {
                    scan.skipped.append(shown)
                }
            }
            scan.problems += unreadable.map { L("“\($0)”: unreadable") }
        }
        return scan
    }

    private struct Existing {
        let name: String
        let isDirectory: Bool
    }

    /// Compares the plan with the read-only mounted volume.
    static func compare(_ scan: inout CopyScan, mount: URL) {
        compare(&scan) { folder in
            let url = folder.isEmpty ? mount : mount.appendingPathComponent(folder)
            let items = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
            return items.map { item in
                (NTFSCopyRunner.normalized(item.lastPathComponent),
                 (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
            }
        }
    }

    /// Compares the plan with the volume, one listing per folder. An existing
    /// file with the same name can be replaced; an existing folder, or a name
    /// that differs only in letter case, cannot.
    static func compare(_ scan: inout CopyScan,
                        list: (String) -> [(name: String, isDirectory: Bool)]) {
        var listings: [String: [String: Existing]] = [:]
        func listing(_ folder: String) -> [String: Existing] {
            if let cached = listings[folder] { return cached }
            var map: [String: Existing] = [:]
            for (name, isDirectory) in list(folder) {
                map[fold(name)] = Existing(name: name, isDirectory: isDirectory)
            }
            listings[folder] = map
            return map
        }
        for folder in scan.folders {
            var parts = folder.split(separator: "/").map(String.init)
            guard let leaf = parts.popLast() else { continue }
            if let found = listing(parts.joined(separator: "/"))[fold(leaf)], !found.isDirectory {
                scan.problems.append(L("“\(folder)”: a file with this name already exists on the disk"))
            }
        }
        for (index, entry) in scan.entries.enumerated() {
            guard let found = listing(entry.folder)[fold(entry.name)] else { continue }
            if found.isDirectory {
                scan.problems.append(L("“\(entry.path)”: a folder with the same name exists on the disk"))
            } else if found.name != entry.name {
                scan.problems.append(L("“\(entry.path)”: already exists on the disk as “\(found.name)” (different letter case); rename or delete it first"))
            } else {
                scan.existing.append(index)
            }
        }
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// One snapshot of the whole operation, as reported by the copy tool.
struct CopyProgress {
    let phase: Int
    let fileIndex: Int
    let fileCount: Int
    let done: UInt64
    let total: UInt64

    var fraction: Double { min(1, Double(done) / Double(total)) }

    func label(names: [String]) -> String {
        let name = fileIndex < names.count ? "«\(names[fileIndex])»" : ""
        switch phase {
        case 0: return L("Disk preflight checks")
        case 1 where names.isEmpty: return L("Applying changes")
        case 1: return L("Writing \(name)")
        case 2: return L("Syncing disk")
        case 3: return L("Verifying \(name) (reading back from disk)")
        case 4: return L("Publishing file names")
        default: return L("Closing and final check")
        }
    }
}

/// Speed and remaining time from the measured throughput, smoothed so the
/// estimate does not jump with every sample.
struct TransferClock {
    private var lastDone: UInt64 = 0
    private var lastTime: TimeInterval = 0
    private var started: TimeInterval = 0
    private(set) var unitsPerSecond: Double = 0

    mutating func update(_ progress: CopyProgress, now: TimeInterval) {
        if started == 0 { started = now; lastTime = now; lastDone = progress.done; return }
        let elapsed = now - lastTime
        guard elapsed >= 0.8 else { return }
        let rate = Double(progress.done &- min(progress.done, lastDone)) / elapsed
        unitsPerSecond = unitsPerSecond == 0 ? rate : unitsPerSecond * 0.7 + rate * 0.3
        lastTime = now
        lastDone = progress.done
    }

    func remaining(_ progress: CopyProgress, now: TimeInterval) -> String {
        guard now - started >= 3, unitsPerSecond > 1 else { return L("Estimating time…") }
        let seconds = Double(progress.total - min(progress.total, progress.done)) / unitsPerSecond
        switch seconds {
        case ..<45: return L("Less than a minute")
        case ..<5400: return L("About \(Int((seconds / 60).rounded(.up))) min")
        default: return String(format: L("About %.1f hours"), locale: AppLanguage.current.locale, seconds / 3600)
        }
    }

    var speed: String {
        unitsPerSecond > 0 ?
            ByteCountFormatter.string(fromByteCount: Int64(unitsPerSecond), countStyle: .file) + "/s" : ""
    }
}

/// Runs the bundled OpenHDDCopy tool. The tool owns every safety rule
/// (preflight, dirty mark, verification); the app only prepares the request.
enum NTFSCopyRunner {
    static var toolURL: URL? {
        Bundle.main.url(forResource: "OpenHDDCopy", withExtension: nil)
    }

    /// Returns a reason when Windows could not create or open `name`.
    static func problem(withName name: String) -> String? {
        if name.isEmpty { return L("empty name") }
        if name.utf16.count > 255 { return L("name too long") }
        if name.lowercased().hasPrefix(".openhdd-") { return L("name reserved for Custodrive") }
        if name.hasSuffix(".") || name.hasSuffix(" ") { return L("ends with a dot or space") }
        let forbidden = CharacterSet(charactersIn: "\"*/:<>?\\|").union(.controlCharacters)
        if name.unicodeScalars.contains(where: { forbidden.contains($0) }) {
            return L("contains one of these characters: \" * / : < > ? \\ |")
        }
        let base = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        let reserved: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        let numbered = (base.hasPrefix("COM") || base.hasPrefix("LPT")) && base.count == 4 &&
            ("1"..."9").contains(String(base.last!))
        if reserved.contains(base) || numbered { return L("name reserved by Windows") }
        return nil
    }

    static func normalized(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }



    /// Devices the user owns (disk images) are opened directly; a USB drive
    /// needs administrator rights, asked by macOS for this one operation.
    static func needsAdministrator(_ partition: String) -> Bool {
        access("/dev/\(partition)", R_OK | W_OK) != 0
    }

    /// Translates the tool's diagnostics into a localized message.
    static func explanation(of text: String) -> String {
        let rules: [(String, String)] = [
            ("journal state suspect", L("Windows did not close the disk properly (NTFS journal open): it was still in use when disconnected. Reconnect it to Windows, use “Safely Remove Hardware” to eject it, then try again.")),
            ("hibernation state uncertain", L("Windows is hibernating or Fast Startup is enabled for this disk. Shut Windows down completely (not just sleep) and try again.")),
            ("dirty volume", L("The disk needs checking (dirty volume). Connect it to Windows and run “chkdsk X: /f” before writing.")),
            ("unfinished OpenHDD transfer", L("A previous copy was interrupted. Connect the disk to Windows and run “chkdsk X: /f”, then try again.")),
            ("previous OpenHDD transfer unresolved", L("A previous copy on this Mac did not finish. Check the disk on Windows with “chkdsk X: /f”, then try again.")),
            ("$TXF_DATA", L("The volume contains Windows transactional data that Custodrive does not modify.")),
            ("already exists", L("An item with the same name already exists in this folder (Windows ignores letter case). Choose another name.")),
            ("not enough free space", L("Not enough free space on the NTFS disk.")),
            ("not found on the volume", L("The specified item or folder no longer exists on the disk.")),
            ("protected system entry", L("NTFS or Windows system files cannot be modified ($MFT, System Volume Information…).")),
            ("junction, symbolic", L("The item is or contains a junction, symbolic link or encrypted file: Custodrive does not follow it and has changed nothing.")),
            ("normal unmount failed", L("macOS cannot unmount the disk: close files opened from that disk and try again.")),
            ("not an external NTFS partition", L("The selected disk is not an external NTFS partition.")),
            ("exclusive open", L("macOS did not grant exclusive disk access: another app or the system is using it. Close files opened from the disk and try again.")),
            ("geometry", L("Disk geometry does not match the expected geometry: operation cancelled.")),
            ("identity", L("The disk changed or was disconnected during the operation.")),
            ("invalid new file name", L("One of the names is invalid on Windows.")),
            ("not a regular file readable", L("One of the source files is unreadable.")),
            ("could not be opened", L("One of the source files cannot be opened.")),
            ("changed while it was being copied", L("A source file changed while copying: no file was published.")),
            ("replace a folder with a file", L("A file cannot replace a folder with the same name.")),
            ("differs in letter case", L("A file with the same name but different letter case already exists on the disk: rename or delete it first.")),
            ("moved into itself", L("A folder cannot be moved into itself.")),
            ("already in that folder", L("The item is already in that folder.")),
            ("overlap", L("One of the items to move is inside another: move them separately.")),
            ("malformed manifest", L("Invalid list of files to copy.")),
        ]
        if let issue = RecoveryIssue(text) {
            return L("Automatic recovery paused: no changes during the recovery attempt.\n") +
                issue.explanation + L("\nSave readable files on another disk and keep the report. Do not delete .OpenHDD files to force writing.")
        }
        var message = rules.first(where: { text.contains($0.0) })?.1 ?? L("Operation failed.")
        if let range = text.range(of: "Earlier batches: ") {
            let count = text[range.upperBound...].prefix(while: \.isNumber)
            message += L(" The first \(count) files were already copied and verified: they remain on the disk.")
        }
        if text.contains("marked for checking") {
            message += L(" The operation stopped after writing began. Before writing again, save a copy of accessible data and check the disk on Windows with “chkdsk X: /f”. Full recovery is not guaranteed.")
        }
        let lines = text.split(separator: "\n").map(String.init)
        let detail = lines.first(where: { $0.hasPrefix("Detail:") }) ??
            lines.first(where: { $0.hasPrefix("Refused") || $0.hasPrefix("Copy failed") }) ??
            lines.last(where: { !$0.isEmpty && !$0.hasPrefix("NO SUCCESS") }) ?? ""
        let shown = detail.hasPrefix("Detail: ") ? String(detail.dropFirst(8)) : detail
        return shown.isEmpty ? message : message + L("\nDetail: ") + shown
    }

    /// Reads the tool's progress line: "phase file count done total".
    static func readProgress(_ file: URL) -> CopyProgress? {
        guard let line = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let parts = line.split(separator: " ")
            .compactMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard parts.count == 5, parts[4] > 0, parts[0] <= 5 else { return nil }
        return CopyProgress(phase: Int(parts[0]), fileIndex: Int(parts[1]),
                            fileCount: Int(parts[2]), done: parts[3], total: parts[4])
    }
}
#endif
