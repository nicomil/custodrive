#if OPENHDD_LOCAL
import AppKit
import Darwin
import Foundation

/// What the user asked to copy onto one NTFS partition.
struct CopyPlan {
    let partition: String
    let volumeName: String
    let sources: [URL]
    let names: [String]
    let sizes: [UInt64]
    /// Existing folder on the volume, relative to its root, or nil for the root.
    let directory: String?

    var totalBytes: UInt64 { sizes.reduce(0, +) }
    var destinationLabel: String { directory.map { "cartella «\($0)»" } ?? "cartella principale" }
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
    }

    let partition: String
    let volumeName: String
    let kind: Kind

    var arguments: [String] {
        switch kind {
        case .delete(let paths): return ["--delete"] + paths
        case .rename(let path, let name): return ["--rename", path, name]
        case .newFolder(let parent, let name): return ["--mkdir", parent, name]
        }
    }

    var title: String {
        switch kind {
        case .delete: return "Eliminazione su «\(volumeName)»"
        case .rename: return "Rinomina su «\(volumeName)»"
        case .newFolder: return "Nuova cartella su «\(volumeName)»"
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
        var arguments: [String] = []
        if let directory = plan.directory { arguments += ["--dir", directory] }
        for (source, name) in zip(plan.sources, plan.names) {
            arguments += [source.path, name]
        }
        return execute(partition: plan.partition, arguments: arguments,
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
        var message = "Copia completata e verificata: \(plan.names.count) file in \(plan.destinationLabel). " +
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
        ]
        var message = rules.first(where: { text.contains($0.0) })?.1 ?? "Operazione non riuscita."
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
