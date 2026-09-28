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

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Devices the user owns (disk images) are opened directly; a USB drive
    /// needs administrator rights, asked by macOS for this one operation.
    static func needsAdministrator(_ partition: String) -> Bool {
        access("/dev/\(partition)", R_OK | W_OK) != 0
    }

    static func run(_ plan: CopyPlan, progressFile: URL) -> CopyOutcome {
        guard let tool = toolURL else {
            return .failure("Componente di copia mancante nell'app.", needsWindowsCheck: false)
        }
        var arguments = ["--disk", plan.partition, "--yes",
                         "--owner-uid", String(getuid()),
                         "--progress", progressFile.path]
        if let directory = plan.directory { arguments += ["--dir", directory] }
        for (source, name) in zip(plan.sources, plan.names) {
            arguments += [source.path, name]
        }

        let process = Process()
        if needsAdministrator(plan.partition) {
            let command = ([tool.path] + arguments).map(shellQuote).joined(separator: " ") + " 2>&1"
            let prompt = "OpenHDD deve scrivere sul disco NTFS «\(plan.volumeName)»."
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e",
                "do shell script \"\(appleScriptLiteral(command))\" with administrator privileges " +
                "with prompt \"\(appleScriptLiteral(prompt))\""]
        } else {
            process.executableURL = tool
            process.arguments = arguments
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch {
            return .failure("Avvio della copia non riuscito: \(error.localizedDescription)",
                            needsWindowsCheck: false)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("(-128)") { return .cancelled }
        if process.terminationStatus == 0, text.contains("PASS:") {
            return .success(summary(of: text, plan: plan))
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
            ("dirty volume", "Il disco risulta da controllare (volume «dirty»). Collegalo a Windows ed esegui «chkdsk X: /f» prima di scrivere."),
            ("unfinished OpenHDD transfer", "Una copia precedente è stata interrotta. Collegalo a Windows ed esegui «chkdsk X: /f», poi riprova."),
            ("previous OpenHDD transfer unresolved", "Una copia precedente su questo Mac non si è conclusa. Controlla il disco su Windows con «chkdsk X: /f», poi riprova."),
            ("hibernation state uncertain", "Windows è in ibernazione o con Avvio rapido attivo su questo disco. Spegni Windows completamente e riprova."),
            ("journal state suspect", "Il journal NTFS non è pulito: il disco non è stato espulso correttamente da Windows. Ricollegalo a Windows ed espellilo."),
            ("$TXF_DATA", "Il volume contiene dati transazionali Windows che OpenHDD non modifica."),
            ("already exists", "Esiste già un file con lo stesso nome (senza distinguere maiuscole e minuscole). Rinomina il file di origine."),
            ("not enough free space", "Spazio libero insufficiente sul disco NTFS."),
            ("destination folder not found", "La cartella di destinazione non esiste più sul disco."),
            ("normal unmount failed", "macOS non riesce a smontare il disco: chiudi i file aperti da quel disco e riprova."),
            ("not an external NTFS partition", "Il disco selezionato non è una partizione NTFS esterna."),
            ("identity", "Il disco è cambiato o è stato scollegato durante l'operazione."),
            ("invalid new file name", "Uno dei nomi non è valido per Windows."),
            ("not a regular file readable", "Uno dei file di origine non è leggibile."),
        ]
        var message = rules.first(where: { text.contains($0.0) })?.1 ?? "Copia non riuscita."
        if text.contains("marked for checking") {
            message += " La copia si è interrotta dopo l'inizio della scrittura: i file già presenti non sono stati modificati, ma il disco va controllato su Windows con «chkdsk X: /f» prima di scriverci di nuovo."
        }
        let lines = text.split(separator: "\n").map(String.init)
        let detail = lines.first(where: { $0.hasPrefix("Refused") || $0.hasPrefix("Copy failed") }) ??
            lines.last(where: { !$0.isEmpty && !$0.hasPrefix("NO SUCCESS") }) ?? ""
        return detail.isEmpty ? message : message + "\nDettaglio: " + detail
    }

    /// Reads the tool's progress line: "index count done total".
    static func readProgress(_ file: URL, plan: CopyPlan) -> Double? {
        guard let line = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let parts = line.split(separator: " ").compactMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard parts.count == 4, plan.totalBytes > 0 else { return nil }
        let index = Int(parts[0])
        guard index < plan.sizes.count else { return nil }
        let before = plan.sizes.prefix(index).reduce(0, +)
        return min(1, Double(before + parts[2]) / Double(plan.totalBytes))
    }
}
#endif
