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
    var destinationLabel: String { destination.isEmpty ? "cartella principale" : "cartella «\(destination)»" }
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

/// URLs collected from drop callbacks, which arrive on background queues.
final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    var all: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

/// What a walk through the chosen files and folders found.
struct CopyScan {
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
    static func scan(_ sources: [URL], into destination: String) -> CopyScan {
        var scan = CopyScan()
        var names: [String: Set<String>] = [:]
        func claim(_ folder: String, _ name: String) -> Bool {
            if names[folder, default: []].insert(fold(name)).inserted { return true }
            scan.problems.append("«\(join(folder, name))»: nome già usato nella stessa cartella (Windows non distingue maiuscole e minuscole)")
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
            else { scan.problems.append("«\(name)»: cartella non leggibile"); continue }
            let rootPath = url.path
            for case let fileURL as URL in walker {
                let relative = String(fileURL.path.dropFirst(rootPath.count))
                    .split(separator: "/").map { NTFSCopyRunner.normalized(String($0)) }
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
                    }
                } else {
                    scan.skipped.append(shown)
                }
            }
            scan.problems += unreadable.map { "«\($0)»: non leggibile" }
        }
        return scan
    }

    private struct Existing {
        let name: String
        let isDirectory: Bool
    }

    /// Compares the plan with the read-only mounted volume. An existing file
    /// with the same name can be replaced; an existing folder, or a name
    /// that differs only in letter case, cannot.
    static func compare(_ scan: inout CopyScan, mount: URL) {
        var listings: [String: [String: Existing]] = [:]
        func listing(_ folder: String) -> [String: Existing] {
            if let cached = listings[folder] { return cached }
            let url = folder.isEmpty ? mount : mount.appendingPathComponent(folder)
            var map: [String: Existing] = [:]
            let items = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
            for item in items {
                let name = NTFSCopyRunner.normalized(item.lastPathComponent)
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                map[fold(name)] = Existing(name: name, isDirectory: isDirectory)
            }
            listings[folder] = map
            return map
        }
        for folder in scan.folders {
            var parts = folder.split(separator: "/").map(String.init)
            guard let leaf = parts.popLast() else { continue }
            if let found = listing(parts.joined(separator: "/"))[fold(leaf)], !found.isDirectory {
                scan.problems.append("«\(folder)»: sul disco esiste già un file con questo nome")
            }
        }
        for (index, entry) in scan.entries.enumerated() {
            guard let found = listing(entry.folder)[fold(entry.name)] else { continue }
            if found.isDirectory {
                scan.problems.append("«\(entry.path)»: sul disco esiste una cartella con lo stesso nome")
            } else if found.name != entry.name {
                scan.problems.append("«\(entry.path)»: sul disco esiste già come «\(found.name)» (maiuscole diverse); rinominalo o eliminalo prima")
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
        case 0: return "Controlli preliminari del disco"
        case 1 where names.isEmpty: return "Applicazione delle modifiche"
        case 1: return "Scrittura di \(name)"
        case 2: return "Sincronizzazione del disco"
        case 3: return "Verifica di \(name) (rilettura dal disco)"
        case 4: return "Pubblicazione dei nomi dei file"
        default: return "Chiusura e controllo finale"
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
        guard now - started >= 3, unitsPerSecond > 1 else { return "Stima del tempo in corso…" }
        let seconds = Double(progress.total - min(progress.total, progress.done)) / unitsPerSecond
        switch seconds {
        case ..<45: return "Meno di un minuto"
        case ..<5400: return "Circa \(Int((seconds / 60).rounded(.up))) min"
        default: return String(format: "Circa %.1f ore", seconds / 3600)
        }
    }

    var speed: String {
        unitsPerSecond > 0 ?
            ByteCountFormatter.string(fromByteCount: Int64(unitsPerSecond), countStyle: .file) + "/s" : ""
    }
}

/// A change to entries already on the volume. Paths are relative to the
/// volume root, "/"-separated; the tool refuses system entries itself.
struct EditRequest {
    enum Kind {
        case delete([String])
        case rename(String, to: String)
        case newFolder(in: String, named: String)
        case move([String], to: String)
    }

    let partition: String
    let volumeName: String
    let kind: Kind

    var arguments: [String] {
        switch kind {
        case .delete(let paths): return ["--delete"] + paths
        case .rename(let path, let name): return ["--rename", path, name]
        case .newFolder(let parent, let name): return ["--mkdir", parent, name]
        case .move(let paths, let destination): return ["--move", destination] + paths
        }
    }

    var title: String {
        switch kind {
        case .delete: return "Eliminazione su «\(volumeName)»"
        case .rename: return "Rinomina su «\(volumeName)»"
        case .newFolder: return "Nuova cartella su «\(volumeName)»"
        case .move: return "Spostamento su «\(volumeName)»"
        }
    }

    var successMessage: String {
        switch kind {
        case .delete(let paths):
            return "Eliminazione completata e verificata: \(paths.count) elemento/i. Il disco è di nuovo in sola lettura."
        case .rename(let path, let name):
            let old = path.split(separator: "/").last.map(String.init) ?? path
            return "«\(old)» rinominato in «\(name)» e verificato. Il disco è di nuovo in sola lettura."
        case .newFolder(_, let name):
            return "Cartella «\(name)» creata e verificata. Il disco è di nuovo in sola lettura."
        case .move(let paths, let destination):
            let target = destination.isEmpty ? "cartella principale" : "«\(destination)»"
            return "Spostamento completato e verificato: \(paths.count) elemento/i in \(target). Il disco è di nuovo in sola lettura."
        }
    }
}

enum CopyOutcome {
    case success(String)
    case cancelled
    case failure(String, needsWindowsCheck: Bool)
}

/// Runs the bundled OpenHDDCopy tool. The tool owns every safety rule
/// (preflight, dirty mark, verification); the app only prepares the request.
enum NTFSCopyRunner {
    static var toolURL: URL? {
        Bundle.main.url(forResource: "OpenHDDCopy", withExtension: nil)
    }

    /// Returns a reason when Windows could not create or open `name`.
    static func problem(withName name: String) -> String? {
        if name.isEmpty { return "nome vuoto" }
        if name.utf16.count > 255 { return "nome troppo lungo" }
        if name.hasPrefix(".OpenHDD-") { return "nome riservato a OpenHDD" }
        if name.hasSuffix(".") || name.hasSuffix(" ") { return "termina con punto o spazio" }
        let forbidden = CharacterSet(charactersIn: "\"*/:<>?\\|").union(.controlCharacters)
        if name.unicodeScalars.contains(where: { forbidden.contains($0) }) {
            return "contiene uno dei caratteri \" * / : < > ? \\ |"
        }
        let base = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        let reserved: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        let numbered = (base.hasPrefix("COM") || base.hasPrefix("LPT")) && base.count == 4 &&
            ("1"..."9").contains(String(base.last!))
        if reserved.contains(base) || numbered { return "nome riservato da Windows" }
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

    static func run(_ plan: CopyPlan, progressFile: URL) -> CopyOutcome {
        guard let manifest = plan.writeManifest() else {
            return .failure("Impossibile preparare l'elenco dei file da copiare.", needsWindowsCheck: false)
        }
        defer { try? FileManager.default.removeItem(at: manifest) }
        return execute(partition: plan.partition, arguments: ["--manifest", manifest.path],
                       progressFile: progressFile) { summary(of: $0, plan: plan) }
    }

    static func run(_ request: EditRequest, progressFile: URL) -> CopyOutcome {
        execute(partition: request.partition, arguments: request.arguments,
                progressFile: progressFile) { text in
            var message = request.successMessage
            if text.contains("Removed ") {
                message += " Rimossi anche i file temporanei di una copia interrotta in precedenza."
            }
            return message
        }
    }

    // The tool runs as the user, so it reads the chosen files with the app's
    // permissions; for a USB drive it asks macOS (authopen) for an
    // administrator-authorised descriptor of that one partition only.
    private static func execute(partition: String, arguments: [String], progressFile: URL,
                                success: (String) -> String) -> CopyOutcome {
        guard let tool = toolURL else {
            return .failure("Componente di copia mancante nell'app.", needsWindowsCheck: false)
        }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["--disk", partition, "--yes",
                             "--owner-uid", String(getuid()),
                             "--progress", progressFile.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch {
            return .failure("Avvio dell'operazione non riuscito: \(error.localizedDescription)",
                            needsWindowsCheck: false)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("(-128)") || text.contains("authorization for the drive was denied") {
            return .cancelled
        }
        if process.terminationStatus == 0, text.contains("PASS:") {
            return .success(success(text))
        }
        return .failure(explanation(of: text), needsWindowsCheck: text.contains("chkdsk"))
    }

    private static func summary(of text: String, plan: CopyPlan) -> String {
        var what = "\(plan.entries.count) file"
        if !plan.folders.isEmpty { what += " e \(plan.folders.count) cartelle" }
        if plan.replacedCount > 0 { what += " (\(plan.replacedCount) sostituiti)" }
        var message = "Copia completata e verificata: \(what) in \(plan.destinationLabel). " +
            "Il disco è di nuovo in sola lettura."
        if text.contains("Removed ") {
            message += " Rimossi anche i file temporanei di una copia interrotta in precedenza."
        }
        if text.contains("read-only remount failed") {
            message = "Copia completata e verificata. Espelli e ricollega il disco per vedere i file."
        }
        return message
    }

    /// Translates the tool's diagnostics into a short Italian message.
    private static func explanation(of text: String) -> String {
        let rules: [(String, String)] = [
            ("journal state suspect", "Windows non ha chiuso correttamente il disco (journal NTFS aperto): era ancora in uso quando è stato scollegato. Ricollegalo a Windows, usa «Rimozione sicura dell'hardware» ed espellilo, poi riprova."),
            ("hibernation state uncertain", "Windows è in ibernazione o con Avvio rapido attivo su questo disco. Spegni Windows completamente (non solo sospensione) e riprova."),
            ("dirty volume", "Il disco risulta da controllare (volume «dirty»). Collegalo a Windows ed esegui «chkdsk X: /f» prima di scrivere."),
            ("unfinished OpenHDD transfer", "Una copia precedente è stata interrotta. Collegalo a Windows ed esegui «chkdsk X: /f», poi riprova."),
            ("previous OpenHDD transfer unresolved", "Una copia precedente su questo Mac non si è conclusa. Controlla il disco su Windows con «chkdsk X: /f», poi riprova."),
            ("$TXF_DATA", "Il volume contiene dati transazionali Windows che OpenHDD non modifica."),
            ("already exists", "Esiste già un elemento con lo stesso nome nella stessa cartella (maiuscole e minuscole non contano per Windows). Scegli un altro nome."),
            ("not enough free space", "Spazio libero insufficiente sul disco NTFS."),
            ("not found on the volume", "L'elemento o la cartella indicati non esistono più sul disco."),
            ("protected system entry", "Non si possono modificare i file di sistema di NTFS o di Windows ($MFT, System Volume Information…)."),
            ("junction, symbolic", "L'elemento è o contiene un collegamento (junction o link simbolico) o un file cifrato: OpenHDD non lo segue e non ha cambiato nulla."),
            ("normal unmount failed", "macOS non riesce a smontare il disco: chiudi i file aperti da quel disco e riprova."),
            ("not an external NTFS partition", "Il disco selezionato non è una partizione NTFS esterna."),
            ("exclusive open", "macOS non ha lasciato l'accesso esclusivo al disco: un'altra app o il sistema lo sta usando. Chiudi i file aperti dal disco e riprova."),
            ("geometry", "La geometria del disco non corrisponde a quella attesa: operazione annullata."),
            ("identity", "Il disco è cambiato o è stato scollegato durante l'operazione."),
            ("invalid new file name", "Uno dei nomi non è valido per Windows."),
            ("not a regular file readable", "Uno dei file di origine non è leggibile."),
            ("could not be opened", "Uno dei file di origine non si può aprire."),
            ("changed while it was being copied", "Uno dei file di origine è stato modificato durante la copia: nessun file è stato pubblicato."),
            ("replace a folder with a file", "Un file non può sostituire una cartella con lo stesso nome."),
            ("differs in letter case", "Sul disco esiste già un file con lo stesso nome ma maiuscole diverse: rinominalo o eliminalo prima."),
            ("moved into itself", "Una cartella non può essere spostata dentro se stessa."),
            ("already in that folder", "L'elemento si trova già in quella cartella."),
            ("overlap", "Tra gli elementi da spostare ce n'è uno contenuto in un altro: spostali separatamente."),
            ("malformed manifest", "Elenco dei file da copiare non valido."),
        ]
        var message = rules.first(where: { text.contains($0.0) })?.1 ?? "Operazione non riuscita."
        if let range = text.range(of: "Earlier batches: ") {
            let count = text[range.upperBound...].prefix(while: \.isNumber)
            message += " I primi \(count) file erano già stati copiati e verificati: restano sul disco."
        }
        if text.contains("marked for checking") {
            message += " L'operazione si è interrotta dopo l'inizio della scrittura: i file non coinvolti non sono stati toccati, ma il disco va controllato su Windows con «chkdsk X: /f» prima di scriverci di nuovo."
        }
        let lines = text.split(separator: "\n").map(String.init)
        let detail = lines.first(where: { $0.hasPrefix("Detail:") }) ??
            lines.first(where: { $0.hasPrefix("Refused") || $0.hasPrefix("Copy failed") }) ??
            lines.last(where: { !$0.isEmpty && !$0.hasPrefix("NO SUCCESS") }) ?? ""
        let shown = detail.hasPrefix("Detail: ") ? String(detail.dropFirst(8)) : detail
        return shown.isEmpty ? message : message + "\nDettaglio: " + shown
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
