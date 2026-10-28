#if OPENHDD_LOCAL
import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Entries dragged inside OpenHDD: "partition\npath".
    static let openhddEntry = NSPasteboard.PasteboardType("com.openhdd.local.entry")
}

/// A Finder-like list of one folder of the volume.
struct BrowserTable: NSViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = BrowserTableView()
        table.coordinator = context.coordinator
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 2)
        let columns: [(String, String, CGFloat, NSSortDescriptor)] = [
            ("name", L("Name"), 320, NSSortDescriptor(key: "name", ascending: true)),
            ("size", L("Size"), 100, NSSortDescriptor(key: "size", ascending: false)),
            ("date", L("Date Modified"), 170, NSSortDescriptor(key: "date", ascending: false)),
        ]
        for (id, title, width, sort) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 160 : 70
            column.sortDescriptorPrototype = sort
            if id == "size" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.registerForDraggedTypes([.fileURL, .openhddEntry])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        context.coordinator.table = table
        #if OPENHDD_UI_SELFTEST
        UISelfTest.table = table
        #endif
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                             NSTextFieldDelegate, NSMenuDelegate {
        let model: BrowserModel
        weak var table: BrowserTableView?
        private var rows: [VolumeEntry] = []
        private var shownVersion = -1
        private var applyingSelection = false
        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.locale = AppLanguage.current.locale
            formatter.timeStyle = .short
            formatter.doesRelativeDateFormatting = true
            return formatter
        }()

        init(model: BrowserModel) {
            self.model = model
        }

        // MARK: Data

        func update() {
            guard let table else { return }
            if shownVersion != model.version {
                shownVersion = model.version
                rows = sorted(model.entries, by: table.sortDescriptors)
                applyingSelection = true
                table.reloadData()
                applyingSelection = false
            }
            let wanted = IndexSet(rows.indices.filter { model.selection.contains(rows[$0].path) })
            if wanted != table.selectedRowIndexes {
                applyingSelection = true
                table.selectRowIndexes(wanted, byExtendingSelection: false)
                applyingSelection = false
            }
            if let pending = model.pendingRename, let row = rows.firstIndex(where: { $0.path == pending }) {
                model.pendingRename = nil
                table.selectRowIndexes([row], byExtendingSelection: false)
                table.scrollRowToVisible(row)
                beginEditing(row: row)
            }
        }

        private func sorted(_ entries: [VolumeEntry], by descriptors: [NSSortDescriptor]) -> [VolumeEntry] {
            let key = descriptors.first?.key ?? "name"
            let ascending = descriptors.first?.ascending ?? true
            return entries.sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                let order: ComparisonResult
                switch key {
                case "size": order = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
                case "date": order = (a.modified ?? .distantPast).compare(b.modified ?? .distantPast)
                default: order = a.name.localizedStandardCompare(b.name)
                }
                if order == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func entryName(at row: Int) -> String? { row >= 0 && row < rows.count ? rows[row].name : nil }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            let selected = model.selection
            rows = sorted(model.entries, by: tableView.sortDescriptors)
            applyingSelection = true
            tableView.reloadData()
            tableView.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].path) }),
                                       byExtendingSelection: false)
            applyingSelection = false
        }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column, row < rows.count else { return nil }
            let entry = rows[row]
            let id = column.identifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
            switch id.rawValue {
            case "name":
                cell.textField?.stringValue = entry.name
                // Editable only while renaming, so clicks select and drag.
                cell.textField?.isEditable = false
                cell.textField?.textColor = entry.special ? .secondaryLabelColor : .labelColor
                cell.imageView?.image = icon(for: entry)
            case "size":
                cell.textField?.stringValue = entry.isFolder ? "—" :
                    ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)
            default:
                cell.textField?.stringValue = entry.modified.map { dateFormatter.string(from: $0) } ?? ""
            }
            return cell
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            if id.rawValue == "name" {
                text.delegate = self
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                ])
            } else {
                text.alignment = id.rawValue == "size" ? .right : .left
                text.textColor = .secondaryLabelColor
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func icon(for entry: VolumeEntry) -> NSImage {
            if entry.special { return NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage() }
            if entry.isFolder { return NSWorkspace.shared.icon(for: .folder) }
            let type = UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
            return NSWorkspace.shared.icon(for: type)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            model.selection = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].path : nil })
        }

        var selectedEntries: [VolumeEntry] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < rows.count else { return }
            model.open(rows[row])
        }

        func openSelection() {
            let selected = selectedEntries
            if selected.count == 1 { model.open(selected[0]) }
        }

        func beginEditingSelection() {
            guard let table, table.selectedRowIndexes.count == 1, model.canWrite,
                  let row = table.selectedRowIndexes.first, !rows[row].special else { return }
            beginEditing(row: row)
        }

        private func beginEditing(row: Int) {
            guard let table, model.canWrite,
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return }
            field.isEditable = true
            table.window?.makeFirstResponder(field)
            // Like the Finder: the name is selected without its extension.
            if let editor = field.currentEditor() {
                let name = rows[row].name as NSString
                let base = rows[row].isFolder ? name.length : (name.deletingPathExtension as NSString).length
                editor.selectedRange = NSRange(location: 0, length: base > 0 ? base : name.length)
            }
        }

        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            guard let table else { return true }
            let row = table.row(for: control)
            guard row >= 0, row < rows.count else { return true }
            return model.rename(rows[row].path, to: fieldEditor.string)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? NSTextField)?.isEditable = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Escape restores the name without renaming.
            if selector == #selector(NSResponder.cancelOperation(_:)), let table {
                let row = table.row(for: control)
                if row >= 0, row < rows.count, let field = control as? NSTextField {
                    field.abortEditing()
                    field.stringValue = rows[row].name
                    field.isEditable = false
                    table.window?.makeFirstResponder(table)
                }
                return true
            }
            return false
        }

        // MARK: Context menu

        func menu(for row: Int) -> NSMenu {
            let menu = NSMenu()
            if row >= 0, row < rows.count {
                if let table, !table.selectedRowIndexes.contains(row) {
                    table.selectRowIndexes([row], byExtendingSelection: false)
                }
                let selected = selectedEntries
                if selected.count == 1 {
                    menu.addItem(item(L("Open"), #selector(menuOpen)))
                }
                if selected.contains(where: { !$0.isFolder }) {
                    menu.addItem(item("Quick Look", #selector(menuQuickLook)))
                }
                if model.canWrite {
                    menu.addItem(.separator())
                    if selected.count == 1 { menu.addItem(item(L("Rename"), #selector(menuRename))) }
                    menu.addItem(item(L("Cut (to Move)"), #selector(menuCut)))
                    menu.addItem(.separator())
                    menu.addItem(item(L("Delete…"), #selector(menuDelete)))
                }
            }
            if model.canWrite {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                menu.addItem(item(L("New Folder"), #selector(menuNewFolder)))
                menu.addItem(item(L("Copy Files Here from Mac…"), #selector(menuCopyHere)))
                if model.canPaste { menu.addItem(item(L("Move Cut Items Here"), #selector(menuPaste))) }
            }
            return menu
        }

        private func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc func menuOpen() { openSelection() }
        @objc func menuQuickLook() { table?.toggleQuickLook() }
        @objc func menuRename() { beginEditingSelection() }
        @objc func menuCut() { model.cutSelection() }
        @objc func menuDelete() { model.delete(selectedEntries.map(\.path)) }
        @objc func menuNewFolder() { model.newFolder() }
        @objc func menuCopyHere() { model.chooseAndCopy() }
        @objc func menuPaste() { model.pasteCut() }

        // MARK: Drag and drop

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard model.canWrite, row < rows.count, let partition = model.record?.bsdName else { return nil }
            let item = NSPasteboardItem()
            item.setString(partition + "\n" + rows[row].path, forType: .openhddEntry)
            return item
        }

        private func draggedPaths(_ info: NSDraggingInfo) -> [String]? {
            guard let items = info.draggingPasteboard.pasteboardItems,
                  let partition = model.record?.bsdName else { return nil }
            let values = items.compactMap { $0.string(forType: .openhddEntry) }
            guard !values.isEmpty else { return nil }
            var paths: [String] = []
            for value in values {
                let parts = value.split(separator: "\n", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == partition else { return [] }
                paths.append(parts[1])
            }
            return paths
        }

        private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
            info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }

        /// The folder a drop lands in: a folder row, or the folder shown.
        private func destination(row: Int, operation: NSTableView.DropOperation) -> String? {
            if operation == .on, row >= 0, row < rows.count {
                return rows[row].isFolder && !rows[row].special ? rows[row].path : nil
            }
            return model.path
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard model.canWrite else { return [] }
            var folder = destination(row: row, operation: operation)
            if folder == nil || operation == .above {
                tableView.setDropRow(-1, dropOperation: .on)
                folder = model.path
            }
            guard let target = folder else { return [] }
            if let paths = draggedPaths(info) {
                let valid = !paths.isEmpty && paths.allSatisfy { path in
                    VolumePath.parent(path) != target && target != path && !target.hasPrefix(path + "/")
                }
                return valid ? .move : []
            }
            return droppedURLs(info).isEmpty ? [] : .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard model.canWrite, let target = destination(row: row, operation: dropOperation) else { return false }
            if let paths = draggedPaths(info) {
                guard !paths.isEmpty else { return false }
                model.move(paths, to: target)
                return true
            }
            let urls = droppedURLs(info)
            guard !urls.isEmpty else { return false }
            model.copy(urls, into: target)
            return true
        }
    }
}

/// Keyboard like the Finder: Return renames, Space previews, ⌘⌫ deletes,
/// ⌘↓ opens, ⌘↑ goes to the enclosing folder, ⌘X / ⌘V move.
final class BrowserTableView: NSTableView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var coordinator: BrowserTable.Coordinator?

    override func keyDown(with event: NSEvent) {
        guard let coordinator else { return super.keyDown(with: event) }
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 36 where !command, 76 where !command: coordinator.beginEditingSelection()
        case 49: toggleQuickLook()
        case 51 where command, 117 where command: coordinator.model.delete(coordinator.selectedEntries.map(\.path))
        case 125 where command: coordinator.openSelection()
        case 126 where command: coordinator.model.goUp()
        default:
            if command, let key = event.charactersIgnoringModifiers?.lowercased() {
                if key == "x" { coordinator.model.cutSelection(); return }
                if key == "v" { coordinator.model.pasteCut(); return }
            }
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row < 0 { deselectAll(nil) }
        return coordinator?.menu(for: row)
    }

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
            return
        }
        coordinator?.model.quickLook { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { coordinator?.model.quickLookItems.count ?? 0 }
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            guard let items = coordinator?.model.quickLookItems, index < items.count else { return nil }
            return items[index] as NSURL
        }
    }
}
#endif
