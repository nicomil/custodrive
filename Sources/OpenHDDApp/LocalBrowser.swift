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
    @Published private(set) var recoveryReports: [String: RecoveryIssue] = [:]
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

    var recoveryIssue: RecoveryIssue? { record.flatMap { recoveryReports[$0.mediaIdentity] } }
    var canWrite: Bool { isNTFS && !sessionChanging && recoveryIssue == nil }

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
            placeholder = L("Select a disk.")
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
            let includeRecovery = recoveryIssue != nil
            loading = true
            if entries.isEmpty { placeholder = L("Reading disk…") }
            Task.detached { [model = self] in
                let result = session.list(folder, includeRecovery: includeRecovery)
                await model.show(result, generation: generation, folder: folder)
            }
        } else if record.isNTFS, let mount = record.mountURL {
            let includeRecovery = recoveryIssue != nil
            loading = true
            if entries.isEmpty { placeholder = L("Reading disk…") }
            Task.detached { [model = self] in
                let result = BrowserModel.listMount(mount, folder: folder, includeRecovery: includeRecovery)
                await model.show(result, generation: generation, folder: folder)
            }
        } else if record.isNTFS {
            loading = false
            entries = []
            version += 1
            placeholder = sessionChanging ? L("Opening disk for editing…") :
                L("The disk is not mounted. Click “Open” to browse it read-only, or “Edit” to make changes.")
        } else {
            loading = false
            entries = []
            version += 1
            placeholder = L("This disk is not NTFS: use Finder.")
        }
    }

    nonisolated static func listMount(_ mount: URL, folder: String, includeRecovery: Bool = false) -> EditSession.ListResult {
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
                if VolumePath.hidden(name, inRoot: folder.isEmpty) &&
                    !(includeRecovery && name.lowercased().hasPrefix(".openhdd-")) { continue }
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
            placeholder = L("Folder not found.")
        case .failed(let text):
            entries = []
            placeholder = L("Cannot read folder. \(text)")
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
            alert(L("Another disk is being edited"),
                  L("Finish editing “\(session.partition)” first."))
            clearQueue()
            return
        }
        sessionChanging = true
        status = (NTFSCopyRunner.needsAdministrator(record.bsdName) ?
            L("macOS will ask for the administrator password. ") : L("Opening disk… ")) +
            L("The disk will remain reserved for Custodrive until you click “Finish Editing”.")
        disks.setOverride(record.bsdName, L("Opening for editing"))
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
            disks.setOverride(partition, L("Editing active"))
            status = L("Editing active: the disk is reserved for Custodrive. Every operation is verified.")
            inspectRecovery(then: next)
        case .cancelled:
            disks.setOverride(partition, nil)
            status = L("Editing cancelled: no changes to the disk.")
            clearQueue()
            disks.refresh(bsdName: partition)
        case .failed(let text):
            disks.setOverride(partition, nil)
            status = text
            clearQueue()
            disks.refresh(bsdName: partition)
            alert(L("Cannot open disk for editing"), text)
        }
    }

    /// Ends the session: the disk is mounted read-only again for the Finder.
    func endEditing(then next: (() -> Void)? = nil) {
        guard let session, !sessionChanging else { next?(); return }
        guard running == nil, queue.isEmpty else {
            status = L("Wait for the current operations to finish.")
            return
        }
        sessionChanging = true
        status = L("Finishing edits and remounting read-only…")
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
                L("Editing finished. Eject and reconnect the disk to see it in Finder.") :
                L("Editing finished: the disk is read-only again and visible in Finder.")
        } else {
            disks.setOverride(partition, L("Check required"))
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

    /// Reuses the engine's complete recovery plan; this command never writes.
    func inspectRecovery(then next: (() -> Void)? = nil) {
        guard let session, editingHere, !sessionChanging, running == nil, preparing == nil,
              let record else { return }
        let identity = record.mediaIdentity
        sessionChanging = true
        preparing = L("Checking recovery read-only; replaced files are being read back…")
        Task.detached { [model = self] in
            let reply = session.call(["inspect-recovery"])
            await MainActor.run {
                model.sessionChanging = false
                model.preparing = nil
                if reply?.first == "ok" {
                    model.recoveryReports[identity] = nil
                    model.status = L("Recovery checks passed without writes. Every change will be verified again.")
                    next?()
                } else {
                    let text = reply?.last ?? L("Session ended during the check.")
                    let refusal = RecoveryIssue(text) == nil ?
                        "recovery journal or temporary entries are invalid or ambiguous\n" + text : text
                    model.recordRecoveryRefusal(refusal, identity: identity)
                    model.clearQueue()
                    model.status = NTFSCopyRunner.explanation(of: text)
                }
                model.reload()
            }
        }
    }

    private func recordRecoveryRefusal(_ text: String, identity: String) {
        if let issue = RecoveryIssue(text) {
            recoveryReports[identity] = issue
            copyRequests = []
            scanToken?.cancel()
            cut = nil
        }
    }

    func recheckRecovery() {
        if editingHere { inspectRecovery() } else { beginEditing() }
    }

    func openRecoveryInFinder() {
        guard let record, recoveryIssue != nil, preparing == nil, !sessionChanging else { return }
        let identity = record.mediaIdentity
        endEditing { [weak self] in
            guard let self, self.record?.mediaIdentity == identity else { return }
            self.disks.openInFinder() // existing mount path also verifies read-only state
        }
    }

    func recoveryReport() -> String? {
        guard let issue = recoveryIssue, let record else { return nil }
        return L("Custodrive — recovery refusal report\nDate: \(Date().ISO8601Format())\nVersion: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("Unknown"))\nSupported journal format: 2 (legacy only when unambiguous)\nVolume: \(record.name) (\(record.bsdName))\nIdentity: \(record.mediaIdentity)\n\n\(issue.explanation)\n\nThe check did not write to the volume. Paths are expected paths,\nnot confirmation that the contents exist or are intact. The report may\ncontain private names: share it only with those providing assistance.\n\nSave readable files on another disk and verify the copies.\nTo copy entire folders, use “Open in Finder” in read-only mode.\nKeep the original image and journal before any repair. Do not delete\ntemporary files to unblock writing. After checking a copy,\n“Check Again” validates everything without forcing recovery.\nIf ambiguity remains, continue read-only and seek assistance.\n\nTechnical diagnostics:\n\(issue.diagnostics)")
    }

    func saveRecoveryReport() {
        guard let report = recoveryReport() else { return }
        let panel = NSSavePanel()
        panel.title = L("Save recovery report")
        panel.nameFieldStringValue = L("Custodrive-recovery.txt")
        panel.message = L("The report contains file names and paths. Save it on your Mac or another disk.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.write(to: url, atomically: true, encoding: .utf8) }
        catch { alert(L("Report not saved"), error.localizedDescription) }
    }

    // MARK: Writes

    private func enqueue(_ operation: PendingOperation) {
        if let disk = disks.records.first(where: { $0.bsdName == operation.partition }),
           recoveryReports[disk.mediaIdentity] != nil {
            operation.discard()
            return
        }
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
            status = L("Cannot prepare the operation.")
            operation.discard()
            return
        }
        running = operation
        canCancel = operation.isCopy
        progress = 0
        progressDetail = L("Preparing…")
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
                var detail = (copying ? L("File") : L("Item")) +
                    L(" \(snapshot.fileIndex + 1) of \(snapshot.fileCount) · ") + snapshot.label(names: names)
                if (snapshot.phase == 1 || snapshot.phase == 3), !clock.speed.isEmpty {
                    detail += " · " + clock.speed
                }
                self.progressDetail = detail
                self.progressRemaining = snapshot.done >= snapshot.total ? L("Almost done") :
                    L("Time remaining: ") + clock.remaining(snapshot, now: now).lowercasedFirst
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
                (text.contains("Removed ") ? L(" Temporary files from an earlier interrupted operation were also removed.") : "")
            if let reveal = operation.revealForRename { pendingRename = reveal }
        } else if text.contains("Cancelled:") {
            var message = L("Copy cancelled: the disk is clean.")
            if let range = text.range(of: "Earlier batches: ") {
                let count = text[range.upperBound...].prefix(while: \.isNumber)
                message += L(" The first \(count) files were already copied and verified and remain on the disk.")
            }
            status = message
            clearQueue()
        } else {
            let explanation = NTFSCopyRunner.explanation(of: text)
            if let disk = disks.records.first(where: { $0.bsdName == operation.partition }) {
                recordRecoveryRefusal(text, identity: disk.mediaIdentity)
            }
            let marked = stage >= 2 || text.contains("marked for checking")
            status = explanation
            clearQueue()
            if marked { disks.setOverride(operation.partition, L("Check required")) }
            if RecoveryIssue(text) == nil {
                alert(marked ? L("\(operation.title): incomplete, check the disk on Windows") :
                        L("\(operation.title): not performed"), explanation)
            }
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
            preparing = L("Cancelling…")
            return
        }
        copyRequests = []
        clearQueue()
        if canCancel, let session {
            canCancel = false
            progressDetail = L("Cancelling: files in the current batch are being removed…")
            session.interrupt()
        }
    }

    // MARK: Copy from the Mac

    /// Copies files and folders from the Mac into `folder` of the selected
    /// disk. Requests are prepared one at a time, then queued for writing.
    func copy(_ sources: [URL], into folder: String) {
        guard let record, canWrite else { return }
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
        preparing = L("Preparing file list…")
        let session = self.session?.partition == record.bsdName && self.session?.isAlive == true ?
            self.session : nil
        let mount = record.mountURL
        let partition = record.bsdName, volume = record.name
        Task.detached { [model = self] in
            var scan = CopyScanner.scan(sources, into: folder, token: token) { files, bytes in
                let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
                Task { @MainActor in
                    if model.preparing != nil { model.preparing = L("Preparing: \(files) files found (\(size))…") }
                }
            }
            if !scan.cancelled {
                await MainActor.run { model.preparing = L("Comparing with files already on the disk…") }
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
                    model.status = L("Preparation cancelled: no changes to the disk.")
                } else {
                    model.planCopy(result, folder: folder, partition: partition, volume: volume)
                }
                model.prepareNextCopy()
            }
        }
    }

    private func listed(_ items: [String], limit: Int = 8) -> String {
        items.prefix(limit).map { "• \($0)" }.joined(separator: "\n") +
            (items.count > limit ? L("\n… and \(items.count - limit) more") : "")
    }

    private func planCopy(_ scan: CopyScan, folder: String, partition: String, volume: String) {
        guard scan.problems.isEmpty else {
            alert(L("Some items cannot be copied this way"),
                  listed(scan.problems, limit: 10) + L("\n\nFix them on your Mac (or the disk) and try again."))
            return
        }
        var plan = CopyPlan(partition: partition, volumeName: volume, entries: scan.entries,
                            folders: scan.folders, destination: folder)
        if !scan.existing.isEmpty {
            let ask = NSAlert()
            ask.messageText = scan.existing.count == 1 ?
                L("An item with the same name already exists") :
                L("\(scan.existing.count) items with the same name already exist")
            ask.informativeText = listed(scan.existing.map { plan.entries[$0].path }) + L("\n\n“Replace”: the file on the disk is replaced only after the new one has been written and verified.\n“Skip These”: existing files stay unchanged.")
            ask.addButton(withTitle: L("Replace"))
            ask.addButton(withTitle: L("Skip These"))
            ask.addButton(withTitle: L("Cancel"))
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
            status = L("Nothing to copy: all files are already on the disk.")
            return
        }
        guard let manifest = plan.writeManifest() else {
            status = L("Cannot prepare file list.")
            return
        }
        #if OPENHDD_UI_SELFTEST
        if let data = try? Data(contentsOf: manifest) {
            FileHandle.standardError.write(Data("[manifest] ".utf8) +
                Data(data.map { $0 == 0 ? UInt8(ascii: "|") : $0 }) + Data("\n".utf8))
        }
        #endif
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: plan.totalBytes), countStyle: .file)
        var what = L("\(plan.entries.count) files")
        if !plan.folders.isEmpty { what += L(" and ") + counted(plan.folders.count, L("folder"), L("folders")) }
        if plan.replacedCount > 0 { what += L(" (\(plan.replacedCount) replaced)") }
        let target = folder.isEmpty ? "«\(volume)»" : "«\(VolumePath.name(folder))»"
        var success = L("Copy completed and verified: \(what) in \(target).")
        if !scan.skipped.isEmpty {
            success += L(" \(scan.skipped.count) symbolic links or special files were skipped.")
        }
        enqueue(PendingOperation(partition: partition, title: L("Copying \(what) (\(size))"),
                                 kind: .copy(manifest: manifest), names: plan.names,
                                 success: success, revealForRename: nil))
    }

    /// Copy via panel (toolbar button and empty-area menu).
    func chooseAndCopy() {
        guard let record, canWrite else { return }
        let panel = NSOpenPanel()
        panel.title = L("Copy to “\(record.name)”")
        panel.prompt = L("Copy Here")
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
                status = candidates.isEmpty ? L("No NTFS disk connected: connect one and try again.") :
                    L("Select the destination NTFS disk on the left, then try again.")
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
            status = L("The disk changed: copy cancelled.")
            return
        }
        copy(request.urls, into: request.folder)
    }

    func cancelIncoming() {
        pendingIncoming = nil
        status = L("Copy cancelled: no changes to the disk.")
    }


    // MARK: Edits

    func newFolder() {
        guard let record, canWrite else { return }
        let taken = Set(entries.map { $0.name.folding(options: .caseInsensitive, locale: nil) })
        var name = L("New Folder")
        var number = 2
        while taken.contains(name.folding(options: .caseInsensitive, locale: nil)) {
            name = L("New Folder \(number)")
            number += 1
        }
        enqueue(PendingOperation(partition: record.bsdName, title: L("New Folder"),
                                 kind: .edit(command: "mkdir", arguments: [path, name]), names: [],
                                 success: L("Folder “\(name)” created and verified."),
                                 revealForRename: VolumePath.join(path, name)))
    }

    /// Inline rename from the table; returns false to keep editing.
    @discardableResult
    func rename(_ entryPath: String, to raw: String) -> Bool {
        guard let record, canWrite else { return true }
        let name = NTFSCopyRunner.normalized(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let old = VolumePath.name(entryPath)
        guard name != old else { return true }
        if let problem = NTFSCopyRunner.problem(withName: name) {
            alert(L("Invalid name"), "«\(name)»: \(problem).")
            return false
        }
        let clash = entries.contains {
            $0.path != entryPath && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
        if clash {
            alert(L("Name already used"), L("“\(name)” already exists in this folder (Windows ignores letter case)."))
            return false
        }
        enqueue(PendingOperation(partition: record.bsdName, title: L("Rename"),
                                 kind: .edit(command: "rename", arguments: [entryPath, name]), names: [],
                                 success: L("“\(old)” renamed to “\(name)”."), revealForRename: nil))
        return true
    }

    func move(_ paths: [String], to folder: String) {
        guard let record, canWrite else { return }
        let moving = paths.filter { VolumePath.parent($0) != folder && folder != $0 &&
            !folder.hasPrefix($0 + "/") }
        guard !moving.isEmpty else { return }
        let target = folder.isEmpty ? "«\(record.name)»" : "«\(VolumePath.name(folder))»"
        enqueue(PendingOperation(partition: record.bsdName, title: L("Moving"),
                                 kind: .edit(command: "move", arguments: [folder] + moving), names: [],
                                 success: (moving.count == 1 ? L("Moved 1 item") : L("Moved \(moving.count) items")) + L(" to \(target)."),
                                 revealForRename: nil))
    }

    func delete(_ paths: [String]) {
        guard let record, canWrite, !paths.isEmpty else { return }
        let names = paths.map(VolumePath.name)
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = paths.count == 1 ? L("Permanently delete “\(names[0])”?") :
            L("Permanently delete \(paths.count) items?")
        confirm.informativeText = (paths.count > 1 ? listed(names) + "\n\n" : "") +
            L("Folders and all their contents will be deleted. NTFS disks have no Trash: this operation cannot be undone.")
        confirm.addButton(withTitle: L("Delete"))
        confirm.addButton(withTitle: L("Cancel"))
        confirm.buttons.first?.hasDestructiveAction = true
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        enqueue(PendingOperation(partition: record.bsdName, title: L("Deleting"),
                                 kind: .edit(command: "delete", arguments: paths), names: [],
                                 success: paths.count == 1 ? L("Deleted 1 item.") : L("Deleted \(paths.count) items."),
                                 revealForRename: nil))
    }

    func cutSelection() {
        guard let record, canWrite, !selection.isEmpty else { return }
        cut = (record.bsdName, Array(selection))
        status = (selection.count == 1 ? L("1 item ready") : L("\(selection.count) items ready")) +
            L(" to move: open the destination folder and press ⌘V.")
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
            status = L("“\(entry.name)” is a link (junction or symbolic link): Custodrive does not follow it.")
            return
        }
        if entry.isFolder { go(to: entry.path); return }
        if editingHere {
            exportCopy(entry, openAfter: true)
        } else if let mount = record?.mountURL {
            NSWorkspace.shared.open(mount.appendingPathComponent(entry.path))
        }
    }

    var canExportSelection: Bool {
        selection.count == 1 && entries.contains {
            selection.contains($0.path) && !$0.isFolder && !$0.special
        } && preparing == nil && running == nil && !sessionChanging
    }

    func exportSelection() {
        guard canExportSelection,
              let entry = entries.first(where: { selection.contains($0.path) }) else { return }
        exportCopy(entry, openAfter: false)
    }

    private func exportCopy(_ entry: VolumeEntry, openAfter: Bool) {
        guard preparing == nil, running == nil, !sessionChanging, !entry.special, !entry.isFolder else { return }
        let session = editingHere ? self.session : nil
        let source = record?.mountURL?.appendingPathComponent(entry.path)
        guard session != nil || source != nil else { return }
        let panel = NSSavePanel()
        panel.title = openAfter ? L("Export and open a copy") : L("Save a copy on your Mac")
        panel.message = L("Choose a destination on your Mac or another disk. The NTFS file stays unchanged. Recovered copies must be verified before use.")
        panel.prompt = openAfter ? L("Export and Open") : L("Save Copy")
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let target = panel.url else { return }
        preparing = L("Exporting “\(entry.name)”…")
        Task.detached { [model = self] in
            let exported: Bool
            if let session {
                exported = session.export(entry.path, to: target)
            } else if let source {
                do {
                    try FileManager.default.copyItem(at: source, to: target)
                    exported = true
                } catch { exported = false }
            } else { exported = false }
            await MainActor.run {
                model.preparing = nil
                if exported {
                    model.status = L("Copy saved. The file on the NTFS disk is unchanged. Verify the copy before use.")
                    if openAfter { NSWorkspace.shared.open(target) }
                } else {
                    model.alert(L("Copy not exported"), L("File unreadable, insufficient space or destination unavailable. If the name already exists, choose another: no local files are overwritten."))
                }
            }
        }
    }

    /// Quick Look of the selected files (space bar).
    func quickLook(then show: @escaping () -> Void) {
        let files = entries.filter { selection.contains($0.path) && !$0.isFolder && !$0.special }
        guard !files.isEmpty else { return }
        materialize(files, purpose: L("Preview")) { [weak self] urls in
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
            status = L("\(purpose): the file is too large to open while editing. Click “Finish Editing” and open it from Finder.")
            return
        }
        preparing = L("\(purpose) of “\(files[0].name)”…")
        Task.detached { [model = self] in
            let urls = files.compactMap { session.export($0.path) }
            await MainActor.run {
                model.preparing = nil
                if urls.count < files.count { model.status = L("\(purpose) failed: file unreadable.") }
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
