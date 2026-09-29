#if OPENHDD_LOCAL
import Darwin
import Foundation

/// One entry of a folder on the NTFS volume.
struct VolumeEntry: Identifiable, Hashable, Sendable {
    let name: String
    /// Relative to the volume root, "/"-separated.
    let path: String
    let isFolder: Bool
    let size: UInt64
    let modified: Date?
    /// Junction, symbolic link or encrypted: shown, never followed.
    let special: Bool

    var id: String { path }
}

/// "1 elemento", "3 elementi".
func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(count) " + (count == 1 ? singular : plural)
}

/// Paths on the volume: "" is the root.
enum VolumePath {
    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func name(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Entries the user never needs to see: NTFS metadata, Windows' own
    /// folder and OpenHDD's temporaries.
    static func hidden(_ name: String, inRoot: Bool) -> Bool {
        name.hasPrefix(".OpenHDD-") ||
            (inRoot && (name.hasPrefix("$") || name == "System Volume Information"))
    }
}

/// A running edit session: the copy tool holds the drive exclusively and
/// serves one request at a time. Authorization and unmount happen once,
/// every write is still its own verified transaction.
final class EditSession: @unchecked Sendable {
    let partition: String
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errors: Pipe
    private var buffer = Data()
    /// Requests are strictly one after another.
    private let lock = NSLock()
    private(set) var isAlive = true
    let temporaryFolder: URL

    private init(partition: String, process: Process, input: FileHandle, output: FileHandle,
                 errors: Pipe, temporaryFolder: URL) {
        self.partition = partition
        self.process = process
        self.input = input
        self.output = output
        self.errors = errors
        self.temporaryFolder = temporaryFolder
    }

    enum StartResult {
        case started(EditSession)
        case cancelled
        case failed(String)
    }

    /// Unmounts the partition and opens it exclusively; macOS asks for the
    /// administrator password once. Blocking: call off the main thread.
    static func start(partition: String) -> StartResult {
        guard let tool = NTFSCopyRunner.toolURL else {
            return .failed("Componente di scrittura mancante nell'app.")
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["--disk", partition, "--session", "--yes",
                             "--owner-uid", String(getuid())]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("openhdd-session-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try process.run()
        } catch {
            return .failed("Avvio della sessione non riuscito: \(error.localizedDescription)")
        }
        let session = EditSession(partition: partition, process: process,
                                  input: input.fileHandleForWriting,
                                  output: output.fileHandleForReading, errors: errors,
                                  temporaryFolder: folder)
        if session.receive() == ["ready"] { return .started(session) }
        process.waitUntilExit()
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try? FileManager.default.removeItem(at: folder)
        if text.contains("authorization for the drive was denied") || text.contains("(-128)") {
            return .cancelled
        }
        return .failed(NTFSCopyRunner.explanation(of: text))
    }

    // MARK: Protocol

    private func field() -> String? {
        while true {
            if let end = buffer.firstIndex(of: 0) {
                let value = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...end)
                return value
            }
            let chunk = output.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    private func receive() -> [String]? {
        guard let first = field(), let count = Int(first), count > 0, count <= 2_000_000 else {
            isAlive = false
            return nil
        }
        var fields: [String] = []
        fields.reserveCapacity(count)
        for _ in 0..<count {
            guard let value = field() else { isAlive = false; return nil }
            fields.append(value)
        }
        return fields
    }

    private func send(_ fields: [String]) -> Bool {
        var data = Data("\(fields.count)".utf8)
        data.append(0)
        for field in fields {
            data.append(contentsOf: Array(field.utf8))
            data.append(0)
        }
        do { try input.write(contentsOf: data) } catch { isAlive = false; return false }
        return true
    }

    /// One request and its reply; nil when the session has ended.
    func call(_ fields: [String]) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        guard isAlive, send(fields) else { return nil }
        return receive()
    }

    /// Asks the running write to stop at a safe point.
    func interrupt() {
        if process.isRunning { process.interrupt() }
    }

    // MARK: Requests

    enum ListResult {
        case entries([VolumeEntry])
        case missing
        case failed(String)
    }

    func list(_ folder: String) -> ListResult {
        guard let reply = call(["list", folder]) else { return .failed("Sessione terminata.") }
        guard reply.first == "ok" else {
            let code = reply.count > 1 ? Int32(reply[1]) ?? 0 : 0
            return code == ENOENT || code == ENOTDIR ? .missing :
                .failed(NTFSCopyRunner.explanation(of: reply.last ?? ""))
        }
        let body = Array(reply.dropFirst().dropLast())
        var entries: [VolumeEntry] = []
        entries.reserveCapacity(body.count / 5)
        let inRoot = folder.isEmpty
        for index in stride(from: 0, to: body.count - body.count % 5, by: 5) {
            let name = body[index]
            let nanoseconds = Int64(body[index + 3]) ?? 0
            if VolumePath.hidden(name, inRoot: inRoot) { continue }
            entries.append(VolumeEntry(
                name: name, path: VolumePath.join(folder, name),
                isFolder: body[index + 1] == "2", size: UInt64(body[index + 2]) ?? 0,
                modified: nanoseconds > 0 ? Date(timeIntervalSince1970: Double(nanoseconds) / 1e9) : nil,
                special: body[index + 4] == "1"))
        }
        return .entries(entries)
    }

    /// Copies a file of the volume into the session's temporary folder, for
    /// opening or Quick Look while the drive is held by the session.
    func export(_ path: String) -> URL? {
        let folder = temporaryFolder.appendingPathComponent(UUID().uuidString)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil else {
            return nil
        }
        let target = folder.appendingPathComponent(VolumePath.name(path))
        guard let reply = call(["export", path, target.path]), reply.first == "ok" else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return target
    }

    /// A copy or an edit; the reply carries the diagnostics as last field.
    func write(_ fields: [String]) -> (ok: Bool, stage: Int, text: String) {
        guard let reply = call(fields) else {
            return (false, 2, "Sessione interrotta: il disco è stato scollegato o lo strumento si è fermato.")
        }
        let stage = reply.first == "error" && reply.count > 2 ? Int(reply[2]) ?? 1 : 0
        return (reply.first == "ok", stage, reply.last ?? "")
    }

    /// Ends the session: the tool remounts the volume read-only and exits.
    /// Returns the tool's final messages.
    func end() -> String {
        if isAlive {
            lock.lock()
            if send(["end"]) { _ = receive() }
            isAlive = false
            lock.unlock()
        }
        try? input.close()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: temporaryFolder)
        return String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    var exitedCleanly: Bool { !process.isRunning && process.terminationStatus == 0 }
}
#endif
