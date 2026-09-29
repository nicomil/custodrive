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
                Section("Dischi esterni") {
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
                ZStack {
                    BrowserTable(model: model)
                    if let placeholder = model.placeholder {
                        VStack(spacing: 12) {
                            Text(placeholder).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if model.isNTFS && model.record?.mountURL == nil && !model.editingHere &&
                                !model.sessionChanging {
                                HStack {
                                    Button("Apri") { model.mountReadOnly() }
                                    Button("Modifica") { model.beginEditing() }
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
            "\(request.urls.count) elementi"
        let target = request.folder.isEmpty ? "nella cartella principale" : "in «\(request.folder)»"
        return HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(.tint)
            Text("Copiare \(what) su «\(request.volume)» \(target)?").font(.callout)
                .lineLimit(2)
            Spacer()
            Button("Annulla") { model.cancelIncoming() }
            Button("Copia") { model.confirmIncoming() }
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
                Label("Modifica attiva", systemImage: "pencil.circle.fill")
                    .foregroundStyle(.orange).font(.caption)
            } else if model.isNTFS {
                Label("Sola lettura", systemImage: "lock.fill")
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
                .disabled(!model.canGoBack).help("Indietro")
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward).help("Avanti")
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!model.canGoUp).help("Cartella superiore (⌘↑)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.newFolder() } label: { Image(systemName: "folder.badge.plus") }
                .disabled(!model.canWrite).help("Nuova cartella (⇧⌘N)")
            Button { model.chooseAndCopy() } label: { Image(systemName: "square.and.arrow.down.on.square") }
                .disabled(!model.canWrite).help("Copia qui file dal Mac…")
            if model.editingHere {
                Button("Termina modifiche") { model.endEditing() }
                    .disabled(model.sessionChanging || model.running != nil)
                    .help("Il disco torna in sola lettura e visibile nel Finder")
            } else {
                Button("Modifica") { model.beginEditing() }
                    .disabled(!model.isNTFS || model.sessionChanging)
                    .help("Una sola password: il disco resta riservato a Custodrive finché non termini")
            }
            Button { model.eject() } label: { Image(systemName: "eject") }
                .disabled(model.record == nil || model.running != nil || model.sessionChanging)
                .help("Espelli")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preparing = model.preparing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(preparing).font(.callout)
                    Spacer()
                    Button("Annulla") { model.cancel() }
                }
            }
            if let running = model.running, let progress = model.progress {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(running.title).font(.callout.bold())
                        if !model.queue.isEmpty {
                            Text("· altre \(model.queue.count) in coda").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(progress * 100)) %").font(.callout.monospacedDigit())
                        if model.canCancel || !model.queue.isEmpty {
                            Button("Annulla") { model.cancel() }
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
        guard model.record != nil else { return "Collega un disco NTFS e selezionalo." }
        let folders = model.entries.filter(\.isFolder).count
        return counted(model.entries.count, "elemento", "elementi") + " (" +
            counted(folders, "cartella", "cartelle") + "). Trascina qui file dal Finder per copiarli."
    }
}
#endif
