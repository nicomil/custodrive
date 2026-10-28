import SwiftUI
import DiskArbitration
import Darwin
import UniformTypeIdentifiers

@main
struct OpenHDDApp: App {
    init() {
        // Native AppKit menus and dialogs follow the explicit app language,
        // including English on a Mac whose system language is Italian/Spanish.
        UserDefaults.standard.set([AppLanguage.current.rawValue], forKey: "AppleLanguages")
    }
    @StateObject private var disks = DiskStore()
    #if OPENHDD_LOCAL
    @NSApplicationDelegateAdaptor(LocalAppDelegate.self) private var delegate
    #endif

    var body: some Scene {
        #if OPENHDD_LOCAL
        // One window: files opened from the Dock or the Services menu go to
        // it instead of opening new windows.
        Window("Custodrive", id: "main") {
            LocalBrowserView(store: disks, model: disks.browser)
                .environment(\.locale, AppLanguage.current.locale)
                .frame(minWidth: 820, minHeight: 480)
                .onAppear {
                    delegate.attach(disks.browser)
                    #if OPENHDD_UI_SELFTEST
                    UISelfTest.runIfRequested(disks.browser)
                    #endif
                }
        }
        .commands {
            MainWindowCommand(delegate: delegate)
            CommandGroup(after: .newItem) {
                Button(L("New Folder")) { disks.browser.newFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button(L("Copy Files Here from Mac…")) { disks.browser.chooseAndCopy() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu(L("Go")) {
                Button(L("Back")) { disks.browser.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button(L("Forward")) { disks.browser.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                Button(L("Enclosing Folder")) { disks.browser.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
            }
        }
        #else
        WindowGroup {
            ContentView(store: disks)
                .environment(\.locale, AppLanguage.current.locale)
                .frame(minWidth: 740, minHeight: 430)
        }
        .windowResizability(.contentSize)
        #endif
        Settings {
            LanguagePicker()
                .padding(20)
                .frame(width: 420)
                .environment(\.locale, AppLanguage.current.locale)
        }
    }
}

#if OPENHDD_LOCAL
/// Hands the delegate a way to open the main window.
struct MainWindowCommand: Commands {
    let delegate: LocalAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let open = openWindow
        let _ = MainActor.assumeIsolated {
            delegate.openMainWindow = { open(id: "main") }
        }
        CommandGroup(after: .windowList) {
            Button(L("Main Window")) { openWindow(id: "main") }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}

/// Finder Services, files dropped on the Dock icon, and a clean end of the
/// edit session when the app quits.
@MainActor
final class LocalAppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: BrowserModel?
    private var pending: [URL] = []
    /// Opens the main window; set by the app's commands, which exist even
    /// when the app was launched by a Services request or a Dock drop and
    /// SwiftUI did not open a window on its own.
    var openMainWindow: (() -> Void)?

    func attach(_ model: BrowserModel) {
        self.model = model
        if !pending.isEmpty {
            let urls = pending
            pending = []
            // Outside the view update that called attach: the confirmation
            // is a modal alert and must not run inside it.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model.incoming(urls) }
            }
        }
    }

    private func deliver(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if let model {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model.incoming(files) }
            }
        } else {
            pending += files
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if self?.model == nil { self?.openMainWindow?() }
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        deliver(urls)
    }

    /// Services menu: "Copia su disco NTFS con Custodrive".
    @objc func copyToNTFS(_ pasteboard: NSPasteboard, userData: String?,
                          error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty { error.pointee = L("No files to copy.") as NSString; return }
        deliver(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, let session = model.session else { return .terminateNow }
        if model.running != nil {
            model.alert(L("Operation in progress"), L("Wait for the operation to finish (or click Cancel) before quitting."))
            return .terminateCancel
        }
        // The disk is handed back read-only before the app goes away.
        DispatchQueue.global().async {
            _ = session.end()
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
#endif

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
                        L("Mounted read-only") : L("ERROR: mount is not read-only")
                }
            }
            return L("Mounted by macOS")
        }
        return isNTFS ? L("Available") : L("Not mounted")
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
    @Published var message: String = L("Select an external partition. No automatic operations.")
    @Published var busy = false
    @Published private var statusOverrides: [String: String] = [:]

    private let session: DASession
    private var byName: [String: DiskRecord] = [:]
    #if OPENHDD_LOCAL
    lazy var browser = BrowserModel(disks: self)
    private var openFinderAfterMount = true
    #endif

    init() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            fatalError(L("Disk Arbitration unavailable"))
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
        let format = (value(kDADiskDescriptionVolumeKindKey, from: description) as? String) ?? L("Unknown")
        let title = (value(kDADiskDescriptionVolumeNameKey, from: description) as? String) ?? bsd
        let size = (value(kDADiskDescriptionMediaSizeKey, from: description) as? NSNumber)?.uint64Value ?? 0
        let mount = value(kDADiskDescriptionVolumePathKey, from: description) as? URL
        let identity = DiskIdentity.identity(disk, description: description)
        if let previous = byName[bsd],
           (previous.mediaIdentity != identity || previous.size != size) {
            statusOverrides.removeValue(forKey: bsd)
            if selected == bsd {
                selected = nil
                message = L("Device changed. Select the partition again.")
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
            message = L("Device disconnected.")
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
                message = L("NTFS is not mounted read-only. Opening blocked.")
                statusOverrides[record.bsdName] = L("Check required")
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
            message = L("Unsupported format or identity changed.")
            return
        }
        busy = true
        statusOverrides[record.bsdName] = L("Mounting")
        message = L("Mounting through macOS…")
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
            statusOverrides[name] = L("Busy")
            message = L("macOS did not mount the volume: disk busy or check required.")
            return
        }
        statusOverrides.removeValue(forKey: name)
        guard let url = byName[name]?.mountURL else {
            message = L("macOS responded, but the volume path is unavailable.")
            return
        }
        #if OPENHDD_LOCAL
        if requestedReadOnly && !mountedReadOnly(url) {
            statusOverrides[name] = L("Check required")
            message = L("NTFS mount not confirmed read-only. Normal unmount in progress.")
            busy = true
            let context = Unmanaged.passRetained(
                NativeMountRequest(store: self, name: name, readOnly: false)).toOpaque()
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault),
                          nativeSafetyUnmountFinished, context)
            return
        }
        #endif
        message = requestedReadOnly ? L("NTFS volume mounted read-only.") : L("Volume opened through macOS.")
        #if OPENHDD_LOCAL
        let reveal = openFinderAfterMount
        openFinderAfterMount = true
        if !reveal { return }
        #endif
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
            message = L("Device identity changed: operation cancelled.")
            return
        }
        if let problem = HelperClient.ensureAvailable() { message = problem; return }
        busy = true
        statusOverrides[record.bsdName] = L("Mounting")
        message = L("Mounting read-only…")
        Task.detached { [store = self] in
            let (code, outcome) = HelperClient.perform("mount-read-only", disk: record)
            await store.finishOperation(record, code: code, outcome: outcome, ejecting: false)
        }
        #endif
    }

    func eject() {
        guard let record = currentSelection(),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, record.bsdName) else {
            message = L("Device no longer present.")
            return
        }
        guard let fresh = freshDescription(disk),
              (value(kDADiskDescriptionMediaSizeKey, from: fresh) as? NSNumber)?.uint64Value == record.size,
              DiskIdentity.identity(disk, description: fresh) == record.mediaIdentity else {
            message = L("Device identity changed: operation cancelled.")
            return
        }
        #if OPENHDD_LOCAL
        guard let whole = DADiskCopyWholeDisk(disk) else {
            message = L("Cannot identify the disk to eject.")
            return
        }
        busy = true
        statusOverrides[record.bsdName] = L("Ejecting")
        message = L("Normally unmounting all volumes…")
        let context = Unmanaged.passRetained(
            NativeEjectRequest(store: self, record: record)).toOpaque()
        DADiskUnmount(whole, DADiskUnmountOptions(kDADiskUnmountOptionWhole),
                      nativeUnmountFinished, context)
        #else
        if let problem = HelperClient.ensureAvailable() { message = problem; return }
        busy = true
        statusOverrides[record.bsdName] = L("Ejecting")
        message = L("Ejecting…")
        Task.detached { [store = self] in
            let (code, outcome) = HelperClient.perform("eject", disk: record)
            await store.finishOperation(record, code: code, outcome: outcome, ejecting: true)
        }
        #endif
    }

    #if OPENHDD_LOCAL
    func nativeSafetyUnmountCompleted(name: String, succeeded: Bool) {
        busy = false
        statusOverrides[name] = L("Check required")
        message = succeeded ? L("Unsafe NTFS mount: volume unmounted. No files opened.") :
            L("NTFS mount not confirmed read-only. Unmount refused: close files and use Eject.")
    }

    func ejectAfterUnmount(_ record: DiskRecord, context: UnsafeMutableRawPointer) {
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, record.bsdName),
              let fresh = freshDescription(disk),
              DiskIdentity.identity(disk, description: fresh) == record.mediaIdentity,
              (value(kDADiskDescriptionMediaSizeKey, from: fresh) as? NSNumber)?.uint64Value == record.size,
              let whole = DADiskCopyWholeDisk(disk) else {
            _ = Unmanaged<NativeEjectRequest>.fromOpaque(context).takeRetainedValue()
            busy = false
            statusOverrides[record.bsdName] = L("Check required")
            message = L("Disk unmounted, but identity changed: ejection cancelled.")
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
            statusOverrides[record.bsdName] = L("Busy")
        }
        message = succeeded ? L("Device ejected. You can disconnect it now.") :
            L("Ejection failed. Check the disk in Finder; no forced ejection.")
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
            statusOverrides[record.bsdName] = L("Mounted read-only")
        } else if code == EBUSY {
            statusOverrides[record.bsdName] = L("Busy")
        } else if code == ENODEV {
            statusOverrides[record.bsdName] = L("Disconnected")
        } else {
            statusOverrides[record.bsdName] = L("Check required")
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
    /// A short state shown next to the disk; nil restores the mount state.
    func setOverride(_ bsdName: String, _ text: String?) {
        statusOverrides[bsdName] = text
    }

    func refresh(bsdName: String) {
        if let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) {
            refresh(disk)
        }
    }

    /// Mounts an NTFS volume read-only for browsing, without opening the Finder.
    func mountReadOnly(_ record: DiskRecord) {
        guard record.isNTFS, record.mountURL == nil, !busy else { return }
        selected = record.bsdName
        openFinderAfterMount = false
        openInFinder()
    }
}
#endif

#if !OPENHDD_LOCAL
private struct ContentView: View {
    @ObservedObject var store: DiskStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OpenHDD").font(.largeTitle.bold())
            Text(L("Read-only NTFS. Manual selection and mounting."))
                .foregroundStyle(.secondary)
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
            Text(store.message).font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button(L("Open Read-Only")) { store.requestReadOnlyMount() }
                    .disabled(store.busy || store.currentSelection()?.isNTFS != true || store.currentSelection()?.isMountedByOpenHDD == true)
                Button(L("Open in Finder")) { store.openInFinder() }
                    .disabled(store.busy || !store.canOpenInFinder(store.currentSelection()))
                Spacer()
                Button(L("Eject")) { store.eject() }
                    .disabled(store.busy || store.currentSelection() == nil)
            }
        }
        .padding(22)
    }
}
#endif
