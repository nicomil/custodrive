import SwiftUI
import DiskArbitration
import Darwin

@main
struct OpenHDDApp: App {
    @StateObject private var disks = DiskStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: disks)
                .frame(minWidth: 740, minHeight: 430)
        }
        .windowResizability(.contentSize)
    }
}

struct DiskRecord: Identifiable {
    let id: String
    let bsdName: String
    let name: String
    let format: String
    let size: UInt64
    let mountURL: URL?
    let isNTFS: Bool
    let isExternal: Bool
    let mediaIdentity: String

    var state: String {
        if let mountURL {
            var info = statfs()
            let valid = mountURL.path.withCString { statfs($0, &info) == 0 }
            if valid {
                let type = withUnsafePointer(to: &info.f_fstypename) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) {
                        String(cString: $0)
                    }
                }
                if type == "openhdd_ntfs" || (isNTFS && type == "ntfs") {
                    return info.f_flags & UInt32(MNT_RDONLY) != 0 ?
                        "Montato in sola lettura" : "ERRORE: mount non sola lettura"
                }
            }
            return "Montato da macOS"
        }
        return isNTFS ? "Disponibile" : "Non montato"
    }

    var isMountedByOpenHDD: Bool {
        guard let mountURL else { return false }
        var info = statfs()
        guard mountURL.path.withCString({ statfs($0, &info) }) == 0 else { return false }
        let type = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) {
                String(cString: $0)
            }
        }
        return type == "openhdd_ntfs"
    }
}

#if OPENHDD_LOCAL
private let nativeFormats: Set<String> = ["apfs", "exfat", "msdos", "fat", "hfs", "ntfs"]
#else
private let nativeFormats: Set<String> = ["apfs", "exfat", "msdos", "fat", "hfs"]
#endif

private final class NativeMountRequest {
    let store: DiskStore
    let name: String
    let readOnly: Bool
    let arguments: UnsafeMutablePointer<Unmanaged<CFString>?>?
    init(store: DiskStore, name: String, readOnly: Bool) {
        self.store = store; self.name = name; self.readOnly = readOnly
        if readOnly {
            let pointer = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 2)
            pointer[0] = .passRetained("rdonly" as CFString)
            pointer[1] = nil
            arguments = pointer
        } else {
            arguments = nil
        }
    }
    deinit {
        arguments?[0]?.release()
        arguments?.deallocate()
    }
}

private func nativeMountFinished(_ disk: DADisk, _ dissenter: DADissenter?,
                                 _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let request = Unmanaged<NativeMountRequest>.fromOpaque(context).takeRetainedValue()
    MainActor.assumeIsolated {
        request.store.nativeMountCompleted(disk, name: request.name,
                                           succeeded: dissenter == nil,
                                           requestedReadOnly: request.readOnly)
    }
}

#if OPENHDD_LOCAL
private func nativeSafetyUnmountFinished(_ disk: DADisk, _ dissenter: DADissenter?,
                                         _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let request = Unmanaged<NativeMountRequest>.fromOpaque(context).takeRetainedValue()
    MainActor.assumeIsolated {
        request.store.nativeSafetyUnmountCompleted(name: request.name,
                                                   succeeded: dissenter == nil)
    }
}

private final class NativeEjectRequest {
    let store: DiskStore
    let record: DiskRecord
    init(store: DiskStore, record: DiskRecord) { self.store = store; self.record = record }
}

private func nativeUnmountFinished(_ disk: DADisk, _ dissenter: DADissenter?,
                                   _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let request = Unmanaged<NativeEjectRequest>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated {
        if dissenter != nil {
            _ = Unmanaged<NativeEjectRequest>.fromOpaque(context).takeRetainedValue()
            request.store.nativeEjectCompleted(request.record, succeeded: false)
        } else {
            request.store.ejectAfterUnmount(request.record, context: context)
        }
    }
}

private func nativeEjectFinished(_ disk: DADisk, _ dissenter: DADissenter?,
                                 _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let request = Unmanaged<NativeEjectRequest>.fromOpaque(context).takeRetainedValue()
    MainActor.assumeIsolated {
        request.store.nativeEjectCompleted(request.record, succeeded: dissenter == nil)
    }
}
#endif

private func diskStore(_ context: UnsafeMutableRawPointer?) -> DiskStore? {
    guard let context else { return nil }
    return Unmanaged<DiskStore>.fromOpaque(context).takeUnretainedValue()
}

private func appeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    MainActor.assumeIsolated { diskStore(context)?.refresh(disk) }
}

private func disappeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    MainActor.assumeIsolated { diskStore(context)?.remove(disk) }
}

private func changed(_ disk: DADisk, _ keys: CFArray, _ context: UnsafeMutableRawPointer?) {
    MainActor.assumeIsolated { diskStore(context)?.refresh(disk) }
}

@MainActor
final class DiskStore: ObservableObject {
    @Published private(set) var records: [DiskRecord] = []
    @Published var selected: String?
    @Published var message: String = "Seleziona una partizione esterna. Nessuna operazione automatica."
    @Published var busy = false
    @Published var copyProgress: Double?
    @Published var copyTitle = ""
    @Published var copyDetail = ""
    @Published var copyRemaining = ""
    @Published private var statusOverrides: [String: String] = [:]

    private let session: DASession
    private var byName: [String: DiskRecord] = [:]

    init() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            fatalError("Disk Arbitration non disponibile")
        }
        self.session = session
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, appeared, opaque)
        DARegisterDiskDisappearedCallback(session, nil, disappeared, opaque)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, changed, opaque)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func freshDescription(_ disk: DADisk) -> [String: Any]? {
        guard let raw = DADiskCopyDescription(disk) else { return nil }
        return raw as? [String: Any]
    }

    private func value(_ key: CFString, from description: [String: Any]) -> Any? {
        description[key as String]
    }

    func refresh(_ disk: DADisk) {
        guard let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }),
              let description = freshDescription(disk) else { return }
        let whole = (value(kDADiskDescriptionMediaWholeKey, from: description) as? Bool) ?? true
        let internalDevice = (value(kDADiskDescriptionDeviceInternalKey, from: description) as? Bool) ?? true
        let removable = (value(kDADiskDescriptionMediaRemovableKey, from: description) as? Bool) ?? false
        let external = !internalDevice || removable
        guard !whole, external else { byName.removeValue(forKey: bsd); publish(); return }
        let format = (value(kDADiskDescriptionVolumeKindKey, from: description) as? String) ?? "Sconosciuto"
        let title = (value(kDADiskDescriptionVolumeNameKey, from: description) as? String) ?? bsd
        let size = (value(kDADiskDescriptionMediaSizeKey, from: description) as? NSNumber)?.uint64Value ?? 0
        let mount = value(kDADiskDescriptionVolumePathKey, from: description) as? URL
        let identity = DiskIdentity.identity(disk, description: description)
        if let previous = byName[bsd],
           (previous.mediaIdentity != identity || previous.size != size) {
            statusOverrides.removeValue(forKey: bsd)
            if selected == bsd {
                selected = nil
                message = "Dispositivo cambiato. Seleziona di nuovo la partizione."
            }
        }
        let record = DiskRecord(id: bsd, bsdName: bsd, name: title, format: format,
                                size: size, mountURL: mount,
                                isNTFS: format.lowercased() == "ntfs",
                                isExternal: external, mediaIdentity: identity)
        byName[bsd] = record
        publish()
    }

    func remove(_ disk: DADisk) {
        guard let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        byName.removeValue(forKey: bsd)
        statusOverrides.removeValue(forKey: bsd)
        if selected == bsd {
            selected = nil
            message = "Dispositivo scollegato."
        }
        publish()
    }

    private func publish() {
        records = byName.values.sorted { $0.bsdName < $1.bsdName }
    }

    func currentSelection() -> DiskRecord? {
        guard let selected else { return nil }
        return byName[selected]
    }

    func state(for record: DiskRecord) -> String {
        statusOverrides[record.bsdName] ?? record.state
    }

    func canOpenInFinder(_ record: DiskRecord?) -> Bool {
        guard let record else { return false }
        #if OPENHDD_LOCAL
        if record.isNTFS { return true }
        #endif
        return record.mountURL != nil || nativeFormats.contains(record.format.lowercased())
    }

    func openInFinder() {
        guard let record = currentSelection() else { return }
        if let url = record.mountURL {
            #if OPENHDD_LOCAL
            if record.isNTFS && !mountedReadOnly(url) {
                message = "NTFS non risulta montato in sola lettura. Apertura bloccata."
                statusOverrides[record.bsdName] = "Verifica necessaria"
                return
            }
            #endif
            NSWorkspace.shared.open(url)
            return
        }
        guard nativeFormats.contains(record.format.lowercased()),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, record.bsdName),
              let fresh = freshDescription(disk),
              DiskIdentity.identity(disk, description: fresh) == record.mediaIdentity else {
            message = "Formato non gestito o identità cambiata."
            return
        }
        busy = true
        statusOverrides[record.bsdName] = "Montaggio in corso"
        message = "Mount tramite macOS in corso…"
        let request = NativeMountRequest(store: self, name: record.bsdName,
                                         readOnly: record.isNTFS)
        let context = Unmanaged.passRetained(request).toOpaque()
        #if OPENHDD_LOCAL
        if record.isNTFS {
            DADiskMountWithArguments(disk, nil,
                DADiskMountOptions(kDADiskMountOptionDefault),
                nativeMountFinished, context, request.arguments)
        } else {
            DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault),
                        nativeMountFinished, context)
        }
        #else
        DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault),
                    nativeMountFinished, context)
        #endif
    }

    private func mountedReadOnly(_ url: URL) -> Bool {
        var info = statfs()
        return url.path.withCString { statfs($0, &info) == 0 } &&
            info.f_flags & UInt32(MNT_RDONLY) != 0
    }

    func nativeMountCompleted(_ disk: DADisk, name: String, succeeded: Bool,
                              requestedReadOnly: Bool) {
        busy = false
        refresh(disk)
        guard succeeded else {
            statusOverrides[name] = "Occupato"
            message = "macOS non ha montato il volume: disco occupato o verifica necessaria."
            return
        }
        statusOverrides.removeValue(forKey: name)
        guard let url = byName[name]?.mountURL else {
            message = "macOS ha risposto, ma il percorso del volume non è disponibile."
            return
        }
        #if OPENHDD_LOCAL
        if requestedReadOnly && !mountedReadOnly(url) {
            statusOverrides[name] = "Verifica necessaria"
            message = "Mount NTFS non confermato in sola lettura. Smontaggio normale in corso."
            busy = true
            let context = Unmanaged.passRetained(
                NativeMountRequest(store: self, name: name, readOnly: false)).toOpaque()
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault),
                          nativeSafetyUnmountFinished, context)
            return
        }
        #endif
        message = requestedReadOnly ? "Volume NTFS montato in sola lettura." : "Volume aperto tramite macOS."
        NSWorkspace.shared.open(url)
    }

    func requestReadOnlyMount() {
        #if OPENHDD_LOCAL
        guard let record = currentSelection(), record.isNTFS else { return }
        openInFinder()
        #else
        guard let record = currentSelection(), record.isNTFS,
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, record.bsdName),
              let fresh = freshDescription(disk),
              DiskIdentity.identity(disk, description: fresh) == record.mediaIdentity,
              (value(kDADiskDescriptionMediaSizeKey, from: fresh) as? NSNumber)?.uint64Value == record.size else {
            message = "Identità del dispositivo cambiata: operazione annullata."
            return
        }
        if let problem = HelperClient.ensureAvailable() { message = problem; return }
        busy = true
        statusOverrides[record.bsdName] = "Montaggio in corso"
        message = "Montaggio in sola lettura in corso…"
        Task.detached { [store = self] in
            let (code, outcome) = HelperClient.perform("mount-read-only", disk: record)
            await store.finishOperation(record, code: code, outcome: outcome, ejecting: false)
        }
        #endif
    }

    func eject() {
        guard let record = currentSelection(),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, record.bsdName) else {
            message = "Dispositivo non più presente."
            return
        }
        guard let fresh = freshDescription(disk),
              (value(kDADiskDescriptionMediaSizeKey, from: fresh) as? NSNumber)?.uint64Value == record.size,
              DiskIdentity.identity(disk, description: fresh) == record.mediaIdentity else {
            message = "Identità del dispositivo cambiata: operazione annullata."
            return
        }
        #if OPENHDD_LOCAL
        guard let whole = DADiskCopyWholeDisk(disk) else {
            message = "Impossibile identificare il disco da espellere."
            return
        }
        busy = true
        statusOverrides[record.bsdName] = "Espulsione in corso"
        message = "Smontaggio normale di tutti i volumi in corso…"
        let context = Unmanaged.passRetained(
            NativeEjectRequest(store: self, record: record)).toOpaque()
        DADiskUnmount(whole, DADiskUnmountOptions(kDADiskUnmountOptionWhole),
                      nativeUnmountFinished, context)
        #else
        if let problem = HelperClient.ensureAvailable() { message = problem; return }
        busy = true
        statusOverrides[record.bsdName] = "Espulsione in corso"
        message = "Espulsione in corso…"
        Task.detached { [store = self] in
            let (code, outcome) = HelperClient.perform("eject", disk: record)
            await store.finishOperation(record, code: code, outcome: outcome, ejecting: true)
        }
        #endif
    }

    #if OPENHDD_LOCAL
    func nativeSafetyUnmountCompleted(name: String, succeeded: Bool) {
        busy = false
        statusOverrides[name] = "Verifica necessaria"
        message = succeeded ? "Mount NTFS non sicuro: volume smontato. Nessun file aperto." :
            "Mount NTFS non confermato in sola lettura. Smontaggio rifiutato: chiudi i file e usa Espelli."
    }

    func ejectAfterUnmount(_ record: DiskRecord, context: UnsafeMutableRawPointer) {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, record.bsdName),
              let fresh = freshDescription(disk),
              DiskIdentity.identity(disk, description: fresh) == record.mediaIdentity,
              (value(kDADiskDescriptionMediaSizeKey, from: fresh) as? NSNumber)?.uint64Value == record.size,
              let whole = DADiskCopyWholeDisk(disk) else {
            _ = Unmanaged<NativeEjectRequest>.fromOpaque(context).takeRetainedValue()
            busy = false
            statusOverrides[record.bsdName] = "Verifica necessaria"
            message = "Disco smontato, ma identità cambiata: espulsione annullata."
            return
        }
        DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault),
                    nativeEjectFinished, context)
    }

    func nativeEjectCompleted(_ record: DiskRecord, succeeded: Bool) {
        busy = false
        if succeeded {
            statusOverrides.removeValue(forKey: record.bsdName)
            if byName[record.bsdName]?.mediaIdentity == record.mediaIdentity {
                byName.removeValue(forKey: record.bsdName)
                publish()
            }
            if selected == record.bsdName { selected = nil }
        } else if byName[record.bsdName]?.mediaIdentity == record.mediaIdentity {
            statusOverrides[record.bsdName] = "Occupato"
        }
        message = succeeded ? "Dispositivo espulso. Ora puoi scollegarlo." :
            "Espulsione non riuscita. Controlla il disco nel Finder; nessuna forzatura."
    }
    #endif

    #if !OPENHDD_LOCAL
    private func finishOperation(_ record: DiskRecord, code: Int32,
                                 outcome: String, ejecting: Bool) {
        busy = false
        message = outcome
        if code == 0 && ejecting {
            statusOverrides.removeValue(forKey: record.bsdName)
            if byName[record.bsdName]?.mediaIdentity == record.mediaIdentity {
                byName.removeValue(forKey: record.bsdName)
                publish()
            }
            if selected == record.bsdName { selected = nil }
        } else if code == 0 {
            statusOverrides[record.bsdName] = "Montato in sola lettura"
        } else if code == EBUSY {
            statusOverrides[record.bsdName] = "Occupato"
        } else if code == ENODEV {
            statusOverrides[record.bsdName] = "Scollegato"
        } else {
            statusOverrides[record.bsdName] = "Verifica necessaria"
        }
        if !(code == 0 && ejecting),
           let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, record.bsdName) {
            refresh(disk)
        }
    }
    #endif
}

#if OPENHDD_LOCAL
extension DiskStore {
    func canCopy(_ record: DiskRecord?) -> Bool {
        guard let record else { return false }
        return record.isNTFS && record.isExternal && !busy
    }

    /// Asks for files and a destination, confirms, then runs the copy.
    func beginCopy() {
        guard let record = currentSelection(), record.isNTFS else { return }
        let panel = NSOpenPanel()
        panel.title = "Scegli i file da copiare su «\(record.name)»"
        panel.prompt = "Avanti"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let sources = panel.urls

        var names: [String] = []
        var sizes: [UInt64] = []
        var problems: [String] = []
        for url in sources {
            let name = NTFSCopyRunner.normalized(url.lastPathComponent)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if values?.isRegularFile != true || values?.isSymbolicLink == true {
                problems.append("«\(name)»: non è un file normale")
            } else if let problem = NTFSCopyRunner.problem(withName: name) {
                problems.append("«\(name)»: \(problem)")
            }
            if names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                problems.append("«\(name)»: scelto due volte")
            }
            names.append(name)
            sizes.append(UInt64(values?.fileSize ?? 0))
        }
        guard problems.isEmpty else {
            alert("Alcuni file non possono essere copiati così", problems.joined(separator: "\n") +
                  "\n\nRinominali sul Mac e riprova.")
            return
        }

        guard let directory = chooseDestination(record) else { return }
        let plan = CopyPlan(partition: record.bsdName, volumeName: record.name,
                            sources: sources, names: names, sizes: sizes,
                            directory: directory.isEmpty ? nil : directory)
        if let mount = record.mountURL {
            let folder = directory.isEmpty ? mount : mount.appendingPathComponent(directory)
            let clashes = names.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            if !clashes.isEmpty {
                alert("File già presenti", "Nella destinazione esistono già: " + clashes.joined(separator: ", ") +
                      ".\nOpenHDD non sovrascrive file esistenti.")
                return
            }
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: plan.totalBytes), countStyle: .file)
        let confirm = NSAlert()
        confirm.messageText = "Copiare \(names.count) file (\(size)) su «\(record.name)»?"
        confirm.informativeText = """
        Destinazione: \(plan.destinationLabel).
        OpenHDD aggiunge solo file nuovi: non modifica né cancella quelli presenti. Durante la copia il disco viene smontato; alla fine ogni file viene riletto e confrontato con l'originale.
        Non scollegare il disco finché non compare «Copia completata». Se la copia si interrompe, i file già presenti restano intatti, ma il disco andrà controllato su Windows con «chkdsk X: /f».
        """
        confirm.addButton(withTitle: "Copia")
        confirm.addButton(withTitle: "Annulla")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        run(plan, record: record)
    }

    /// Returns "" for the root, a relative path for a folder, nil if cancelled.
    private func chooseDestination(_ record: DiskRecord) -> String? {
        guard let mount = record.mountURL else { return "" }
        let ask = NSAlert()
        ask.messageText = "Dove copiare i file su «\(record.name)»?"
        ask.addButton(withTitle: "Cartella principale")
        ask.addButton(withTitle: "Scegli cartella…")
        ask.addButton(withTitle: "Annulla")
        switch ask.runModal() {
        case .alertFirstButtonReturn: return ""
        case .alertSecondButtonReturn: break
        default: return nil
        }
        let panel = NSOpenPanel()
        panel.title = "Cartella di destinazione su «\(record.name)»"
        panel.prompt = "Scegli"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = mount
        guard panel.runModal() == .OK, let chosen = panel.url?.standardizedFileURL else { return nil }
        let root = mount.standardizedFileURL.path
        let path = chosen.path
        guard path == root || path.hasPrefix(root + "/") else {
            alert("Cartella non valida", "Scegli una cartella che si trova sul disco «\(record.name)».")
            return nil
        }
        return NTFSCopyRunner.normalized(String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    func canEdit(_ record: DiskRecord?) -> Bool {
        guard let record else { return false }
        return record.isNTFS && record.isExternal && record.mountURL != nil && !busy
    }

    /// Picks entries on the read-only mounted volume and returns their paths
    /// relative to the volume root.
    private func pickOnVolume(_ record: DiskRecord, title: String, prompt: String,
                              files: Bool, folders: Bool, multiple: Bool,
                              allowRoot: Bool = false) -> [String]? {
        guard let mount = record.mountURL?.standardizedFileURL else {
            alert("Disco non montato", "Apri prima il disco in sola lettura.")
            return nil
        }
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = files
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = multiple
        panel.canCreateDirectories = false
        panel.directoryURL = mount
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        let root = mount.path
        var paths: [String] = []
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            if path == root {
                if allowRoot { paths.append(""); continue }
                alert("Scelta non valida", "Scegli file o cartelle dentro il disco, non il disco intero.")
                return nil
            }
            guard path.hasPrefix(root + "/") else {
                alert("Scelta non valida", "Scegli elementi che si trovano sul disco «\(record.name)».")
                return nil
            }
            paths.append(NTFSCopyRunner.normalized(String(path.dropFirst(root.count + 1))))
        }
        return paths
    }

    private func askName(_ title: String, _ text: String, initial: String) -> String? {
        let ask = NSAlert()
        ask.messageText = title
        ask.informativeText = text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = initial
        ask.accessoryView = field
        ask.addButton(withTitle: "OK")
        ask.addButton(withTitle: "Annulla")
        ask.window.initialFirstResponder = field
        guard ask.runModal() == .alertFirstButtonReturn else { return nil }
        let name = NTFSCopyRunner.normalized(field.stringValue.trimmingCharacters(in: .newlines))
        if let problem = NTFSCopyRunner.problem(withName: name) {
            alert("Nome non valido", "«\(name)»: \(problem).")
            return nil
        }
        return name
    }

    func beginDelete() {
        guard let record = currentSelection(), canEdit(record),
              let paths = pickOnVolume(record, title: "Elementi da eliminare su «\(record.name)»",
                                       prompt: "Avanti", files: true, folders: true,
                                       multiple: true) else { return }
        let names = paths.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
        let listed = names.prefix(8).map { "• \($0)" }.joined(separator: "\n") +
            (names.count > 8 ? "\n… e altri \(names.count - 8)" : "")
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Eliminare definitivamente \(paths.count) elemento/i da «\(record.name)»?"
        confirm.informativeText = """
        \(listed)

        Le cartelle vengono eliminate con tutto il contenuto. Sul disco NTFS non c'è un Cestino: l'operazione non si può annullare.
        """
        confirm.addButton(withTitle: "Elimina")
        confirm.addButton(withTitle: "Annulla")
        confirm.buttons.first?.hasDestructiveAction = true
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        run(EditRequest(partition: record.bsdName, volumeName: record.name,
                        kind: .delete(paths)), record: record)
    }

    func beginRename() {
        guard let record = currentSelection(), canEdit(record),
              let path = pickOnVolume(record, title: "Elemento da rinominare su «\(record.name)»",
                                      prompt: "Rinomina…", files: true, folders: true,
                                      multiple: false)?.first else { return }
        let old = path.split(separator: "/").last.map(String.init) ?? path
        guard let name = askName("Rinomina «\(old)»", "Nuovo nome (resta nella stessa cartella):",
                                 initial: old), name != old else { return }
        run(EditRequest(partition: record.bsdName, volumeName: record.name,
                        kind: .rename(path, to: name)), record: record)
    }

    func beginNewFolder() {
        guard let record = currentSelection(), canEdit(record),
              let parent = pickOnVolume(record, title: "Dove creare la cartella su «\(record.name)»",
                                        prompt: "Qui", files: false, folders: true,
                                        multiple: false, allowRoot: true)?.first,
              let name = askName("Nuova cartella",
                                 "Nome della cartella in «\(parent.isEmpty ? record.name : parent)»:",
                                 initial: "Nuova cartella") else { return }
        run(EditRequest(partition: record.bsdName, volumeName: record.name,
                        kind: .newFolder(in: parent, named: name)), record: record)
    }

    private func run(_ plan: CopyPlan, record: DiskRecord) {
        perform(record: record, title: "Copia su «\(plan.volumeName)»", names: plan.names,
                partition: plan.partition, editing: false) { progressFile in
            NTFSCopyRunner.run(plan, progressFile: progressFile)
        }
    }

    private func run(_ request: EditRequest, record: DiskRecord) {
        perform(record: record, title: request.title, names: [],
                partition: request.partition, editing: true) { progressFile in
            NTFSCopyRunner.run(request, progressFile: progressFile)
        }
    }

    /// Runs one engine operation with the shared progress bar and outcome
    /// handling; the engine itself enforces every safety rule.
    private func perform(record: DiskRecord, title: String, names: [String],
                         partition: String, editing: Bool,
                         operation: @escaping @Sendable (URL) -> CopyOutcome) {
        let progressFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("openhdd-progress-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: progressFile.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            message = "Impossibile preparare l'operazione."
            return
        }
        busy = true
        copyProgress = 0
        copyTitle = title
        statusOverrides[record.bsdName] = editing ? "Modifica in corso" : "Trasferimento in corso"
        message = NTFSCopyRunner.needsAdministrator(partition) ?
            "macOS chiederà la password di amministratore per scrivere sul disco." :
            "Operazione in corso…"
        copyDetail = "Preparazione…"
        copyRemaining = ""
        var clock = TransferClock()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let progress = NTFSCopyRunner.readProgress(progressFile) else { return }
                let now = ProcessInfo.processInfo.systemUptime
                clock.update(progress, now: now)
                self.copyProgress = progress.fraction
                var detail = (editing ? "Elemento" : "File") +
                    " \(progress.fileIndex + 1) di \(progress.fileCount) · " +
                    progress.label(names: names)
                if (progress.phase == 1 || progress.phase == 3), !clock.speed.isEmpty {
                    detail += " · " + clock.speed
                }
                self.copyDetail = detail
                self.copyRemaining = progress.done >= progress.total ?
                    "Quasi finito" : "Tempo rimanente: " + clock.remaining(progress, now: now).lowercasedFirst
                self.message = "Non scollegare il disco finché l'operazione non è completata."
            }
        }
        Task.detached { [store = self] in
            let outcome = operation(progressFile)
            try? FileManager.default.removeItem(at: progressFile)
            await MainActor.run {
                timer.invalidate()
                store.finishCopy(outcome, record: record, editing: editing)
            }
        }
    }

    private func finishCopy(_ outcome: CopyOutcome, record: DiskRecord, editing: Bool = false) {
        busy = false
        copyProgress = nil
        copyDetail = ""
        copyRemaining = ""
        switch outcome {
        case .success(let text):
            statusOverrides.removeValue(forKey: record.bsdName)
            message = text
        case .cancelled:
            statusOverrides.removeValue(forKey: record.bsdName)
            message = "Operazione annullata: nessuna modifica al disco."
        case .failure(let text, let needsWindowsCheck):
            statusOverrides[record.bsdName] = needsWindowsCheck ? "Verifica necessaria" : "Non scritto"
            message = text
            let noun = editing ? "Modifica" : "Copia"
            alert(needsWindowsCheck ? "\(noun) non completata: controlla il disco su Windows" :
                    "\(noun) non eseguita", text)
        }
        if let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, record.bsdName) {
            refresh(disk)
        }
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
#endif

private struct ContentView: View {
    @ObservedObject var store: DiskStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            #if OPENHDD_LOCAL
            Text("OpenHDD Local").font(.largeTitle.bold())
            #else
            Text("OpenHDD").font(.largeTitle.bold())
            #endif
            #if OPENHDD_LOCAL
            Text("Lettura NTFS tramite macOS. Copia di file nuovi su NTFS con verifica.")
                .foregroundStyle(.secondary)
            #else
            Text("NTFS in sola lettura. Selezione e montaggio manuali.")
                .foregroundStyle(.secondary)
            #endif
            List(selection: $store.selected) {
                // The status is part of the row identity: List rows on macOS
                // are redrawn only when their data changes.
                ForEach(store.records, id: \.bsdName) { disk in
                    HStack {
                        Image(systemName: "externaldrive")
                        VStack(alignment: .leading) {
                            Text(disk.name).font(.headline)
                            Text("\(disk.bsdName) · \(disk.format) · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: disk.size), countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(store.state(for: disk)).font(.caption)
                    }
                    .tag(disk.id)
                    .id("\(disk.bsdName)|\(store.state(for: disk))")
                }
            }
            #if OPENHDD_LOCAL
            if let progress = store.copyProgress {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(store.copyTitle).font(.callout.bold())
                        Spacer()
                        Text("\(Int(progress * 100)) %").font(.callout.monospacedDigit())
                    }
                    ProgressView(value: progress)
                    Text(store.copyDetail).font(.caption)
                    Text(store.copyRemaining).font(.caption).foregroundStyle(.secondary)
                }
            }
            #endif
            Text(store.message).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("Apri in sola lettura") { store.requestReadOnlyMount() }
                    #if OPENHDD_LOCAL
                    .disabled(store.busy || store.currentSelection()?.isNTFS != true)
                    #else
                    .disabled(store.busy || store.currentSelection()?.isNTFS != true || store.currentSelection()?.isMountedByOpenHDD == true)
                    #endif
                Button("Apri nel Finder") { store.openInFinder() }
                    .disabled(store.busy || !store.canOpenInFinder(store.currentSelection()))
                #if OPENHDD_LOCAL
                Button("Copia sul disco…") { store.beginCopy() }
                    .disabled(!store.canCopy(store.currentSelection()))
                Menu("Modifica") {
                    Button("Nuova cartella…") { store.beginNewFolder() }
                    Button("Rinomina…") { store.beginRename() }
                    Divider()
                    Button("Elimina…", role: .destructive) { store.beginDelete() }
                }
                .fixedSize()
                .disabled(!store.canEdit(store.currentSelection()))
                #endif
                Spacer()
                Button("Espelli") { store.eject() }
                    .disabled(store.busy || store.currentSelection() == nil)
            }
        }
        .padding(22)
    }
}
