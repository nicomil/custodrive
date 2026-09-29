#if OPENHDD_LOCAL
import AppKit
import Quartz
import SwiftUI

/// A write waiting for its turn. Writes run one after another inside the
/// edit session of their disk; each is still a separate verified transaction.
struct PendingOperation: Identifiable {
    enum Kind {
        case copy(manifest: URL)
        case edit(command: String, arguments: [String])
    }

    let id = UUID()
    let partition: String
    let title: String
    let kind: Kind
    /// Names shown while it runs (files of a copy).
    let names: [String]
    let success: String
    /// Selected and renamed right away when it appears (a new folder).
    let revealForRename: String?

    var isCopy: Bool { if case .copy = kind { return true } else { return false } }

    func fields(progress: URL) -> [String] {
        switch kind {
        case .copy(let manifest): return ["copy", manifest.path, progress.path]
        case .edit(let command, let arguments): return [command, progress.path] + arguments
        }
    }

    func discard() {
        if case .copy(let manifest) = kind { try? FileManager.default.removeItem(at: manifest) }
    }
}

@MainActor
final class BrowserModel: ObservableObject {
    let disks: DiskStore

    @Published private(set) var path = ""
    @Published private(set) var entries: [VolumeEntry] = []
    /// Bumped whenever `entries` is replaced, so the table reloads once.
    @Published private(set) var version = 0
    @Published var selection: Set<String> = []
    @Published private(set) var loading = false
    @Published private(set) var placeholder: String?
    @Published private(set) var session: EditSession?
    @Published private(set) var sessionChanging = false
    @Published private(set) var running: PendingOperation?
    @Published private(set) var queue: [PendingOperation] = []
    @Published private(set) var progress: Double?
    @Published private(set) var progressDetail = ""
    @Published private(set) var progressRemaining = ""
    @Published private(set) var canCancel = false
    @Published private(set) var preparing: String?
    @Published var status = ""
    /// A folder created by the user: the table selects it and starts renaming.
    @Published var pendingRename: String?
    /// Entries cut with ⌘X, moved by ⌘V into the folder shown then.
    @Published private(set) var cut: (partition: String, paths: [String])?
    private(set) var quickLookItems: [URL] = []

    /// Files handed over by the Finder's Services menu or the Dock, waiting
    /// for the user to confirm the target shown in the window.
    struct IncomingRequest {
        var urls: [URL]
        let partition: String
        let volume: String
        let folder: String
    }
    @Published private(set) var pendingIncoming: IncomingRequest?

    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var shownDisk: String?
    private var listGeneration = 0
    private var scanToken: ScanToken?
    /// Copies asked while another one is being prepared wait here.
    private var copyRequests: [(sources: [URL], folder: String, partition: String)] = []

    init(disks: DiskStore) {
        self.disks = disks
    }

    // MARK: Disk and session state

    var record: DiskRecord? { disks.currentSelection() }

    var isNTFS: Bool { record.map { $0.isNTFS && $0.isExternal } ?? false }

    /// The session holds this disk right now.
    var editingHere: Bool {
        guard let session, let record else { return false }
        return session.partition == record.bsdName && session.isAlive
    }

    var canWrite: Bool { isNTFS && !sessionChanging }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { !path.isEmpty }

    /// Called when the selected disk or its mount changes.
    func diskChanged() {
        guard let record else {
            shownDisk = nil
            loading = false
            entries = []
            version += 1
            placeholder = "Seleziona un disco."
            return
        }
        if shownDisk != record.bsdName {
            shownDisk = record.bsdName
            path = ""
            backStack = []
            forwardStack = []
            selection = []
        }
        reload()
    }

    // MARK: Navigation

    func go(to folder: String) {
        guard folder != path else { return }
        backStack.append(path)
        forwardStack = []
        path = folder
        selection = []
        reload()
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        path = previous
        selection = []
        reload()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        path = next
        selection = []
        reload()
    }

    func goUp() {
        guard canGoUp else { return }
        let child = path
        go(to: VolumePath.parent(path))
        selection = [child]
    }

    /// Lists the current folder: through the session while it holds the
    /// disk, otherwise from the read-only mount of macOS.
    func reload() {
        guard let record else { return }
        listGeneration += 1
        let generation = listGeneration
        let folder = path
        if editingHere, let session {
            loading = true
            if entries.isEmpty { placeholder = "Lettura del disco…" }
            Task.detached { [model = self] in
                let result = session.list(folder)
                await model.show(result, generation: generation, folder: folder)
            }
        } else if record.isNTFS, let mount = record.mountURL {
            loading = true
            if entries.isEmpty { placeholder = "Lettura del disco…" }
            Task.detached { [model = self] in
                let result = BrowserModel.listMount(mount, folder: folder)
                await model.show(result, generation: generation, folder: folder)
            }
        } else if record.isNTFS {
            loading = false
            entries = []
            version += 1
            placeholder = sessionChanging ? "Apertura del disco per le modifiche…" :
                "Il disco non è montato. Premi «Apri» per vederlo in sola lettura, o «Modifica» per lavorarci."
        } else {
            loading = false
            entries = []
            version += 1
            placeholder = "Questo disco non è NTFS: usa il Finder."
        }
    }

    nonisolated static func listMount(_ mount: URL, folder: String) -> EditSession.ListResult {
        let url = folder.isEmpty ? mount : mount.appendingPathComponent(folder)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                                      .isSymbolicLinkKey]
        do {
            let items = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: [])
            var entries: [VolumeEntry] = []
            entries.reserveCapacity(items.count)
            for item in items {
                let name = NTFSCopyRunner.normalized(item.lastPathComponent)
                if VolumePath.hidden(name, inRoot: folder.isEmpty) { continue }
                let values = try? item.resourceValues(forKeys: Set(keys))
                entries.append(VolumeEntry(
                    name: name, path: VolumePath.join(folder, name),
                    isFolder: values?.isDirectory == true,
                    size: UInt64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate,
                    special: values?.isSymbolicLink == true))
            }
            return .entries(entries)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func show(_ result: EditSession.ListResult, generation: Int, folder: String) {
        guard generation == listGeneration else { return }
        loading = false
        switch result {
        case .entries(let list):
            entries = list.sorted {
                $0.isFolder != $1.isFolder ? $0.isFolder :
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            placeholder = nil
            selection = selection.filter { path in list.contains { $0.path == path } }
        case .missing:
            // The folder vanished (deleted or moved): climb to the root.
            if !folder.isEmpty {
                path = VolumePath.parent(folder)
                reload()
                return
            }
            entries = []
            placeholder = "Cartella non trovata."
        case .failed(let text):
            entries = []
            placeholder = "Impossibile leggere la cartella. \(text)"
        }
        version += 1
    }

    // MARK: Session

    /// Starts an edit session on the selected disk: one password, one
    /// unmount. The disk stays reserved to OpenHDD until it is ended.
    func beginEditing(then next: (() -> Void)? = nil) {
        guard let record, isNTFS, !sessionChanging else { return }
        if editingHere { next?(); return }
        if let session, session.isAlive {
            alert("Un altro disco è in modifica",
                  "Termina prima le modifiche su «\(session.partition)».")
            clearQueue()
            return
        }
        sessionChanging = true
        status = (NTFSCopyRunner.needsAdministrator(record.bsdName) ?
            "macOS chiederà la password di amministratore. " : "Apertura del disco… ") +
            "Il disco resterà riservato a Custodrive finché non premi «Termina modifiche»."
        disks.setOverride(record.bsdName, "Apertura per le modifiche")
        let partition = record.bsdName
        Task.detached { [model = self] in
            let result = EditSession.start(partition: partition)
            await model.sessionStarted(result, partition: partition, then: next)
        }
    }

    private func sessionStarted(_ result: EditSession.StartResult, partition: String,
                                then next: (() -> Void)?) {
        sessionChanging = false
        switch result {
        case .started(let started):
            session = started
            disks.setOverride(partition, "Modifica attiva")
            status = "Modifica attiva: il disco è riservato a Custodrive. Ogni operazione viene verificata."
            reload()
            next?()
        case .cancelled:
            disks.setOverride(partition, nil)
            status = "Modifica annullata: nessuna modifica al disco."
            clearQueue()
            disks.refresh(bsdName: partition)
        case .failed(let text):
            disks.setOverride(partition, nil)
            status = text
            clearQueue()
            disks.refresh(bsdName: partition)
            alert("Impossibile aprire il disco per le modifiche", text)
        }
    }

    /// Ends the session: the disk is mounted read-only again for the Finder.
    func endEditing(then next: (() -> Void)? = nil) {
        guard let session, !sessionChanging else { next?(); return }
        guard running == nil, queue.isEmpty else {
            status = "Attendi la fine delle operazioni in corso."
            return
        }
        sessionChanging = true
        status = "Chiusura delle modifiche e rimontaggio in sola lettura…"
        let partition = session.partition
        Task.detached { [model = self] in
            let text = session.end()
            let clean = session.exitedCleanly
            await model.sessionEnded(partition: partition, text: text, clean: clean, then: next)
        }
    }

    private func sessionEnded(partition: String, text: String, clean: Bool, then next: (() -> Void)?) {
        session = nil
        sessionChanging = false
        if clean {
            disks.setOverride(partition, nil)
            status = text.contains("remount failed") ?
                "Modifiche concluse. Espelli e ricollega il disco per vederlo nel Finder." :
                "Modifiche concluse: il disco è di nuovo in sola lettura e visibile nel Finder."
        } else {
            disks.setOverride(partition, "Verifica necessaria")
            status = NTFSCopyRunner.explanation(of: text)
        }
        disks.refresh(bsdName: partition)
        reload()
        next?()
    }

    /// Ends a session that holds the disk before the app quits.
    nonisolated func endForTermination(_ session: EditSession) {
        _ = session.end()
    }

    func eject() {
        guard record != nil else { return }
        if session != nil {
            endEditing { [weak self] in self?.disks.eject() }
        } else {
            disks.eject()
        }
    }

    func mountReadOnly() {
        guard let record, record.isNTFS, !editingHere else { return }
        disks.mountReadOnly(record)
    }

    // MARK: Writes

    private func enqueue(_ operation: PendingOperation) {
        queue.append(operation)
        runNext()
    }

    private func clearQueue() {
        queue.forEach { $0.discard() }
        queue = []
    }

    private func runNext() {
        guard running == nil, !sessionChanging, let next = queue.first else { return }
        if session?.partition != next.partition || session?.isAlive != true {
            if disks.currentSelection()?.bsdName != next.partition {
                disks.selected = next.partition
            }
            beginEditing { [weak self] in self?.runNext() }
            return
        }
        queue.removeFirst()
        run(next)
    }

    private func run(_ operation: PendingOperation) {
        guard let session else { return }
        let progressFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("openhdd-progress-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: progressFile.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            status = "Impossibile preparare l'operazione."
            operation.discard()
            return
        }
        running = operation
        canCancel = operation.isCopy
        progress = 0
        progressDetail = "Preparazione…"
        progressRemaining = ""
        var clock = TransferClock()
        let names = operation.names
        let copying = operation.isCopy
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let snapshot = NTFSCopyRunner.readProgress(progressFile) else { return }
                let now = ProcessInfo.processInfo.systemUptime
                clock.update(snapshot, now: now)
                self.progress = snapshot.fraction
                guard self.canCancel || !copying else { return }
                var detail = (copying ? "File" : "Elemento") +
                    " \(snapshot.fileIndex + 1) di \(snapshot.fileCount) · " + snapshot.label(names: names)
                if (snapshot.phase == 1 || snapshot.phase == 3), !clock.speed.isEmpty {
                    detail += " · " + clock.speed
                }
                self.progressDetail = detail
                self.progressRemaining = snapshot.done >= snapshot.total ? "Quasi finito" :
                    "Tempo rimanente: " + clock.remaining(snapshot, now: now).lowercasedFirst
            }
        }
        let fields = operation.fields(progress: progressFile)
        Task.detached { [model = self] in
            let result = session.write(fields)
            try? FileManager.default.removeItem(at: progressFile)
            operation.discard()
            await MainActor.run {
                timer.invalidate()
                model.finished(operation, ok: result.ok, stage: result.stage, text: result.text)
            }
        }
    }

    private func finished(_ operation: PendingOperation, ok: Bool, stage: Int, text: String) {
        #if OPENHDD_UI_SELFTEST
        FileHandle.standardError.write(Data("[\(operation.title)] ok=\(ok) fields=\(operation.fields(progress: URL(fileURLWithPath: "/p")))\n\(text)\n".utf8))
        #endif
        running = nil
        progress = nil
        canCancel = false
        progressDetail = ""
        progressRemaining = ""
        if ok {
            status = operation.success +
                (text.contains("Removed ") ? " Rimossi anche i temporanei di un'operazione interrotta in precedenza." : "")
            if let reveal = operation.revealForRename { pendingRename = reveal }
        } else if text.contains("Cancelled:") {
            var message = "Copia annullata: il disco è pulito."
            if let range = text.range(of: "Earlier batches: ") {
                let count = text[range.upperBound...].prefix(while: \.isNumber)
                message += " I primi \(count) file erano già stati copiati e verificati e restano sul disco."
            }
            status = message
            clearQueue()
        } else {
            let explanation = NTFSCopyRunner.explanation(of: text)
            let marked = stage >= 2 || text.contains("marked for checking")
            status = explanation
            clearQueue()
            if marked { disks.setOverride(operation.partition, "Verifica necessaria") }
            alert(marked ? "\(operation.title): non completata, controlla il disco su Windows" :
                    "\(operation.title): non eseguita", explanation)
            if session?.isAlive == false { endEditing() }
        }
        reload()
        runNext()
    }

    /// Stops the folder walk, or the running copy at a safe point; queued
    /// operations are dropped.
    func cancel() {
        if let scanToken {
            copyRequests = []
            scanToken.cancel()
            preparing = "Annullamento…"
            return
        }
        copyRequests = []
        clearQueue()
        if canCancel, let session {
            canCancel = false
            progressDetail = "Annullamento in corso: i file del lotto in corso vengono rimossi…"
            session.interrupt()
        }
    }

    // MARK: Copy from the Mac

    /// Copies files and folders from the Mac into `folder` of the selected
    /// disk. Requests are prepared one at a time, then queued for writing.
    func copy(_ sources: [URL], into folder: String) {
        guard let record, isNTFS else { return }
        copyRequests.append((sources, folder, record.bsdName))
        prepareNextCopy()
    }

    private func prepareNextCopy() {
        guard scanToken == nil, !copyRequests.isEmpty else { return }
        let request = copyRequests.removeFirst()
        guard let record = disks.records.first(where: { $0.bsdName == request.partition }) else {
            prepareNextCopy()
            return
        }
        let sources = request.sources, folder = request.folder
        let token = ScanToken()
        scanToken = token
        preparing = "Preparazione dell'elenco dei file…"
        let session = self.session?.partition == record.bsdName && self.session?.isAlive == true ?
            self.session : nil
        let mount = record.mountURL
        let partition = record.bsdName, volume = record.name
        Task.detached { [model = self] in
            var scan = CopyScanner.scan(sources, into: folder, token: token) { files, bytes in
                let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
                Task { @MainActor in
                    if model.preparing != nil { model.preparing = "Preparazione: \(files) file trovati (\(size))…" }
                }
            }
            if !scan.cancelled {
                await MainActor.run { model.preparing = "Confronto con i file già presenti sul disco…" }
                if let session {
                    CopyScanner.compare(&scan) { path in
                        if case .entries(let list) = session.list(path) {
                            return list.map { ($0.name, $0.isFolder) }
                        }
                        return []
                    }
                } else if let mount {
                    CopyScanner.compare(&scan, mount: mount)
                }
            }
            let result = scan
            await MainActor.run {
                model.preparing = nil
                model.scanToken = nil
                if result.cancelled || token.isCancelled {
                    model.status = "Preparazione annullata: nessuna modifica al disco."
                } else {
                    model.planCopy(result, folder: folder, partition: partition, volume: volume)
                }
                model.prepareNextCopy()
            }
        }
    }

    private func listed(_ items: [String], limit: Int = 8) -> String {
        items.prefix(limit).map { "• \($0)" }.joined(separator: "\n") +
            (items.count > limit ? "\n… e altri \(items.count - limit)" : "")
    }

    private func planCopy(_ scan: CopyScan, folder: String, partition: String, volume: String) {
        guard scan.problems.isEmpty else {
            alert("Alcuni elementi non possono essere copiati così",
                  listed(scan.problems, limit: 10) + "\n\nSistemali sul Mac (o sul disco) e riprova.")
            return
        }
        var plan = CopyPlan(partition: partition, volumeName: volume, entries: scan.entries,
                            folders: scan.folders, destination: folder)
        if !scan.existing.isEmpty {
            let ask = NSAlert()
            ask.messageText = scan.existing.count == 1 ?
                "Un elemento con lo stesso nome esiste già" :
                "\(scan.existing.count) elementi con lo stesso nome esistono già"
            ask.informativeText = listed(scan.existing.map { plan.entries[$0].path }) + """


            «Sostituisci»: il file sul disco viene sostituito solo dopo che il nuovo è stato scritto e verificato.
            «Salta questi»: i file già presenti restano come sono.
            """
            ask.addButton(withTitle: "Sostituisci")
            ask.addButton(withTitle: "Salta questi")
            ask.addButton(withTitle: "Annulla")
            switch ask.runModal() {
            case .alertFirstButtonReturn:
                for index in scan.existing { plan.entries[index].replace = true }
            case .alertSecondButtonReturn:
                let skip = Set(scan.existing)
                plan.entries = plan.entries.enumerated().filter { !skip.contains($0.offset) }.map(\.element)
            default:
                return
            }
        }
        guard !plan.entries.isEmpty || !plan.folders.isEmpty else {
            status = "Niente da copiare: tutti i file sono già sul disco."
            return
        }
        guard let manifest = plan.writeManifest() else {
            status = "Impossibile preparare l'elenco dei file."
            return
        }
        #if OPENHDD_UI_SELFTEST
        if let data = try? Data(contentsOf: manifest) {
            FileHandle.standardError.write(Data("[manifest] ".utf8) +
                Data(data.map { $0 == 0 ? UInt8(ascii: "|") : $0 }) + Data("\n".utf8))
        }
        #endif
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: plan.totalBytes), countStyle: .file)
        var what = "\(plan.entries.count) file"
        if !plan.folders.isEmpty { what += " e " + counted(plan.folders.count, "cartella", "cartelle") }
        if plan.replacedCount > 0 { what += " (\(plan.replacedCount) sostituiti)" }
        let target = folder.isEmpty ? "«\(volume)»" : "«\(VolumePath.name(folder))»"
        var success = "Copia completata e verificata: \(what) in \(target)."
        if !scan.skipped.isEmpty {
            success += " Non copiati \(scan.skipped.count) link simbolici o file speciali."
        }
        enqueue(PendingOperation(partition: partition, title: "Copia di \(what) (\(size))",
                                 kind: .copy(manifest: manifest), names: plan.names,
                                 success: success, revealForRename: nil))
    }

    /// Copy via panel (toolbar button and empty-area menu).
    func chooseAndCopy() {
        guard let record, isNTFS else { return }
        let panel = NSOpenPanel()
        panel.title = "Copia su «\(record.name)»"
        panel.prompt = "Copia qui"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        copy(panel.urls, into: path)
    }

    /// Files from the Finder's Services menu or dropped on the Dock icon.
    func incoming(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let candidates = disks.records.filter { $0.isNTFS && $0.isExternal }
        if !isNTFS {
            guard candidates.count == 1 else {
                status = candidates.isEmpty ? "Nessun disco NTFS collegato: collegane uno e riprova." :
                    "Seleziona a sinistra il disco NTFS su cui copiare, poi riprova."
                return
            }
            disks.selected = candidates[0].bsdName
            diskChanged()
        }
        // A request from outside the window always names its target first:
        // nothing is written to a disk the user did not see chosen. Repeated
        // deliveries of the same request are merged, not stacked.
        guard let record else { return }
        if var pending = pendingIncoming, pending.partition == record.bsdName {
            for url in urls where !pending.urls.contains(url) { pending.urls.append(url) }
            pendingIncoming = pending
        } else {
            pendingIncoming = IncomingRequest(urls: urls, partition: record.bsdName,
                                              volume: record.name, folder: path)
        }
    }

    func confirmIncoming() {
        guard let request = pendingIncoming else { return }
        pendingIncoming = nil
        guard record?.bsdName == request.partition else {
            status = "Il disco è cambiato: copia annullata."
            return
        }
        copy(request.urls, into: request.folder)
    }

    func cancelIncoming() {
        pendingIncoming = nil
        status = "Copia annullata: nessuna modifica al disco."
    }


    // MARK: Edits

    func newFolder() {
        guard let record, isNTFS else { return }
        let taken = Set(entries.map { $0.name.folding(options: .caseInsensitive, locale: nil) })
        var name = "Nuova cartella"
        var number = 2
        while taken.contains(name.folding(options: .caseInsensitive, locale: nil)) {
            name = "Nuova cartella \(number)"
            number += 1
        }
        enqueue(PendingOperation(partition: record.bsdName, title: "Nuova cartella",
                                 kind: .edit(command: "mkdir", arguments: [path, name]), names: [],
                                 success: "Cartella «\(name)» creata e verificata.",
                                 revealForRename: VolumePath.join(path, name)))
    }

    /// Inline rename from the table; returns false to keep editing.
    @discardableResult
    func rename(_ entryPath: String, to raw: String) -> Bool {
        guard let record, isNTFS else { return true }
        let name = NTFSCopyRunner.normalized(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let old = VolumePath.name(entryPath)
        guard name != old else { return true }
        if let problem = NTFSCopyRunner.problem(withName: name) {
            alert("Nome non valido", "«\(name)»: \(problem).")
            return false
        }
        let clash = entries.contains {
            $0.path != entryPath && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
        if clash {
            alert("Nome già usato", "In questa cartella esiste già «\(name)» (Windows non distingue maiuscole e minuscole).")
            return false
        }
        enqueue(PendingOperation(partition: record.bsdName, title: "Rinomina",
                                 kind: .edit(command: "rename", arguments: [entryPath, name]), names: [],
                                 success: "«\(old)» rinominato in «\(name)».", revealForRename: nil))
        return true
    }

    func move(_ paths: [String], to folder: String) {
        guard let record, isNTFS else { return }
        let moving = paths.filter { VolumePath.parent($0) != folder && folder != $0 &&
            !folder.hasPrefix($0 + "/") }
        guard !moving.isEmpty else { return }
        let target = folder.isEmpty ? "«\(record.name)»" : "«\(VolumePath.name(folder))»"
        enqueue(PendingOperation(partition: record.bsdName, title: "Spostamento",
                                 kind: .edit(command: "move", arguments: [folder] + moving), names: [],
                                 success: (moving.count == 1 ? "Spostato 1 elemento" : "Spostati \(moving.count) elementi") + " in \(target).",
                                 revealForRename: nil))
    }

    func delete(_ paths: [String]) {
        guard let record, isNTFS, !paths.isEmpty else { return }
        let names = paths.map(VolumePath.name)
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = paths.count == 1 ? "Eliminare definitivamente «\(names[0])»?" :
            "Eliminare definitivamente \(paths.count) elementi?"
        confirm.informativeText = (paths.count > 1 ? listed(names) + "\n\n" : "") +
            "Le cartelle vengono eliminate con tutto il contenuto. Sul disco NTFS non c'è un Cestino: l'operazione non si può annullare."
        confirm.addButton(withTitle: "Elimina")
        confirm.addButton(withTitle: "Annulla")
        confirm.buttons.first?.hasDestructiveAction = true
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        enqueue(PendingOperation(partition: record.bsdName, title: "Eliminazione",
                                 kind: .edit(command: "delete", arguments: paths), names: [],
                                 success: paths.count == 1 ? "Eliminato 1 elemento." : "Eliminati \(paths.count) elementi.",
                                 revealForRename: nil))
    }

    func cutSelection() {
        guard let record, isNTFS, !selection.isEmpty else { return }
        cut = (record.bsdName, Array(selection))
        status = (selection.count == 1 ? "1 elemento pronto" : "\(selection.count) elementi pronti") +
            " da spostare: apri la cartella di destinazione e premi ⌘V."
    }

    var canPaste: Bool { cut != nil && cut?.partition == record?.bsdName }

    func pasteCut() {
        guard let cut, canPaste else { return }
        self.cut = nil
        move(cut.paths, to: path)
    }

    // MARK: Opening and Quick Look

    func open(_ entry: VolumeEntry) {
        if entry.special {
            status = "«\(entry.name)» è un collegamento (junction o link): Custodrive non lo segue."
            return
        }
        if entry.isFolder { go(to: entry.path); return }
        materialize([entry], purpose: "Apertura") { urls in
            if let url = urls.first { NSWorkspace.shared.open(url) }
        }
    }

    /// Quick Look of the selected files (space bar).
    func quickLook(then show: @escaping () -> Void) {
        let files = entries.filter { selection.contains($0.path) && !$0.isFolder && !$0.special }
        guard !files.isEmpty else { return }
        materialize(files, purpose: "Anteprima") { [weak self] urls in
            self?.quickLookItems = urls
            if !urls.isEmpty { show() }
        }
    }

    /// Local URLs for files of the volume: the read-only mount when there is
    /// one, otherwise a copy exported through the session (size-limited so
    /// a preview never turns into a long transfer).
    private func materialize(_ files: [VolumeEntry], purpose: String,
                             done: @escaping ([URL]) -> Void) {
        if !editingHere, let mount = record?.mountURL {
            done(files.map { mount.appendingPathComponent($0.path) })
            return
        }
        guard let session, editingHere else { return }
        let limit: UInt64 = 2 * 1024 * 1024 * 1024
        guard files.allSatisfy({ $0.size <= limit }) else {
            status = "\(purpose): il file è troppo grande da aprire durante le modifiche. Premi «Termina modifiche» e aprilo dal Finder."
            return
        }
        preparing = "\(purpose) di «\(files[0].name)»…"
        Task.detached { [model = self] in
            let urls = files.compactMap { session.export($0.path) }
            await MainActor.run {
                model.preparing = nil
                if urls.count < files.count { model.status = "\(purpose) non riuscita: file non leggibile." }
                done(urls)
            }
        }
    }

    // MARK: Helpers

    func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
#endif
