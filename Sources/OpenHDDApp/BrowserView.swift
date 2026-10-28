#if OPENHDD_LOCAL
import AppKit
import SwiftUI

/// Custodrive's window: disks on the left, the selected folder of the
/// NTFS volume on the right, operations at the bottom.
struct LocalBrowserView: View {
    @ObservedObject var store: DiskStore
    @ObservedObject var model: BrowserModel

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selected) {
                Section(L("External Disks")) {
                    ForEach(store.records, id: \.bsdName) { disk in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(disk.name, systemImage: disk.isNTFS ? "externaldrive.fill" : "externaldrive")
                            Text("\(disk.format.uppercased()) · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: disk.size), countStyle: .file)) · \(store.state(for: disk))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .tag(disk.bsdName)
                        .id("\(disk.bsdName)|\(store.state(for: disk))")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                if let request = model.pendingIncoming {
                    incomingBar(request)
                    Divider()
                }
                pathBar
                Divider()
                if let issue = model.recoveryIssue {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L("Recovery paused — writes blocked"), systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        ScrollView {
                            Text(issue.explanation).font(.callout).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(height: 110)
                        Text(L("Save readable files on another disk. Do not delete the journal or temporary files."))
                            .font(.callout)
                            .lineLimit(2)
                        HStack {
                            Button(L("Save Report…")) { model.saveRecoveryReport() }
                            Button(L("Save Selected File…")) { model.exportSelection() }
                                .disabled(!model.canExportSelection)
                        }
                        HStack {
                            Button(L("Open in Finder")) { model.openRecoveryInFinder() }
                                .disabled(model.sessionChanging || model.preparing != nil || model.running != nil)
                            Button(L("Check Again")) { model.recheckRecovery() }
                                .disabled(model.sessionChanging || model.preparing != nil || model.running != nil)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1))
                    Divider()
                }
                ZStack {
                    BrowserTable(model: model)
                    if let placeholder = model.placeholder {
                        VStack(spacing: 12) {
                            Text(placeholder).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if model.isNTFS && model.record?.mountURL == nil && !model.editingHere &&
                                !model.sessionChanging {
                                HStack {
                                    Button(L("Open")) { model.mountReadOnly() }
                                    Button(L("Edit")) { model.beginEditing() }.disabled(!model.canWrite)
                                }
                            }
                        }
                        .padding(30)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                    }
                }
                Divider()
                footer
            }
            .toolbar { toolbar }
        }
        .onChange(of: store.selected) { model.diskChanged() }
        .onReceive(store.$records) { _ in
            // Mount changes (a session ending, a read-only mount) refresh the view.
            model.diskChanged()
        }
        .onAppear { model.diskChanged() }
    }

    private func incomingBar(_ request: BrowserModel.IncomingRequest) -> some View {
        let what = request.urls.count == 1 ? "«\(request.urls[0].lastPathComponent)»" :
            L("\(request.urls.count) items")
        let target = request.folder.isEmpty ? L("in the root folder") : L("in “\(request.folder)”")
        return HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(.tint)
            Text(L("Copy \(what) to “\(request.volume)” \(target)?")).font(.callout)
                .lineLimit(2)
            Spacer()
            Button(L("Cancel")) { model.cancelIncoming() }
            Button(L("Copy")) { model.confirmIncoming() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.tint.opacity(0.12))
    }

    private var pathBar: some View {
        HStack(spacing: 4) {
            if let record = model.record {
                Button(record.name) { model.go(to: "") }.buttonStyle(.link)
                let parts = model.path.split(separator: "/").map(String.init)
                ForEach(parts.indices, id: \.self) { index in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(parts[index]) {
                        model.go(to: parts[...index].joined(separator: "/"))
                    }
                    .buttonStyle(.link)
                    .disabled(index == parts.count - 1)
                }
            }
            Spacer()
            if model.editingHere {
                Label(model.recoveryIssue == nil ? L("Editing active") : L("Recovery browsing"), systemImage: "pencil.circle.fill")
                    .foregroundStyle(.orange).font(.caption)
            } else if model.isNTFS {
                Label(L("Read-only"), systemImage: "lock.fill")
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack).help(L("Back"))
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward).help(L("Forward"))
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!model.canGoUp).help(L("Enclosing Folder (⌘↑)"))
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ToolbarLanguageMenu()
            Button { model.newFolder() } label: { Image(systemName: "folder.badge.plus") }
                .disabled(!model.canWrite).help(L("New Folder (⇧⌘N)"))
            Button { model.chooseAndCopy() } label: { Image(systemName: "square.and.arrow.down.on.square") }
                .disabled(!model.canWrite).help(L("Copy Files Here from Mac…"))
            if model.editingHere {
                Button(L("Finish Editing")) { model.endEditing() }
                    .disabled(model.sessionChanging || model.running != nil || model.preparing != nil)
                    .help(L("The disk becomes read-only again and visible in Finder"))
            } else {
                Button(L("Edit")) { model.beginEditing() }
                    .disabled(!model.canWrite)
                    .help(L("One password: the disk stays reserved for Custodrive until you finish editing"))
            }
            Button { model.eject() } label: { Image(systemName: "eject") }
                .disabled(model.record == nil || model.running != nil || model.sessionChanging || model.preparing != nil)
                .help(L("Eject"))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preparing = model.preparing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(preparing).font(.callout)
                    Spacer()
                    if !model.sessionChanging { Button(L("Cancel")) { model.cancel() } }
                }
            }
            if let running = model.running, let progress = model.progress {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(running.title).font(.callout.bold())
                        if !model.queue.isEmpty {
                            Text(L("· \(model.queue.count) more queued")).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(progress * 100)) %").font(.callout.monospacedDigit())
                        if model.canCancel || !model.queue.isEmpty {
                            Button(L("Cancel")) { model.cancel() }
                        }
                    }
                    ProgressView(value: progress)
                    Text(model.progressDetail).font(.caption).lineLimit(1)
                    if !model.progressRemaining.isEmpty {
                        Text(model.progressRemaining).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text(model.status.isEmpty ? summary : model.status)
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        guard model.record != nil else { return L("Connect an NTFS disk and select it.") }
        let folders = model.entries.filter(\.isFolder).count
        return counted(model.entries.count, L("item"), L("items")) + " (" +
            counted(folders, L("folder"), L("folders")) + L("). Drag files here from Finder to copy them.")
    }
}

private struct ToolbarLanguageMenu: View {
    @AppStorage(AppLanguage.preferenceKey) private var selected: AppLanguage = .english

    var body: some View {
        Menu {
            Picker(L("Language"), selection: $selected) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.name).tag(language)
                }
            }
            if selected != .current {
                Text(L("Restart Custodrive to apply the selected language."))
            }
        } label: {
            Label(L("Language"), systemImage: "globe")
        }
        .help(L("The language takes effect the next time the app starts."))
    }
}
#endif
