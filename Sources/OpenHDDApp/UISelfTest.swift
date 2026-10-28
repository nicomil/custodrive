#if OPENHDD_LOCAL && OPENHDD_UI_SELFTEST
import AppKit
import Darwin
import Quartz

/// Test build only: drives the real table data source (drag validation and
/// drops), the edit session and Quick Look inside the running app, on the
/// disk named by OPENHDD_UI_SELFTEST_DISK, and writes a report to
/// OPENHDD_UI_SELFTEST_REPORT. Never compiled into the normal app.
@MainActor
enum UISelfTest {
    static weak var table: BrowserTableView?
    private static var lines: [String] = []
    private static var reportPath = ""

    static func runIfRequested(_ model: BrowserModel) {
        let environment = ProcessInfo.processInfo.environment
        guard let disk = environment["OPENHDD_UI_SELFTEST_DISK"],
              let report = environment["OPENHDD_UI_SELFTEST_REPORT"],
              let source = environment["OPENHDD_UI_SELFTEST_SOURCE"] else { return }
        reportPath = report + ".partial"
        check("self-test started", true)
        Task { @MainActor in
            await run(model, disk: disk, source: URL(fileURLWithPath: source))
            try? lines.joined(separator: "\n").appending("\n")
                .write(toFile: report, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        lines.append((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : ": " + detail))
        try? lines.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
    }

    private static func wait(_ seconds: Double = 60, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    private static func idle(_ model: BrowserModel) async -> Bool {
        await wait { model.running == nil && model.queue.isEmpty && model.preparing == nil &&
            !model.sessionChanging && !model.loading }
    }

    private static func row(_ name: String) -> Int? {
        guard let table, let coordinator = table.coordinator else { return nil }
        return (0..<coordinator.numberOfRows(in: table)).first { coordinator.entryName(at: $0) == name }
    }

    private static func run(_ model: BrowserModel, disk: String, source: URL) async {
        guard await wait(until: { model.disks.records.contains { $0.name == disk } }),
              let record = model.disks.records.first(where: { $0.name == disk }) else {
            check("disk appears", false); return
        }
        model.disks.selected = record.bsdName
        model.diskChanged()
        check("browse read-only mount", await wait { row("old.bin") != nil })

        if ProcessInfo.processInfo.environment["OPENHDD_UI_SELFTEST_RECOVERY"] == "1" {
            await recovery(model, source: source)
            return
        }

        model.beginEditing()
        let started = await wait { model.editingHere }
        let settled = await idle(model)
        check("session starts", started && settled)
        check("listing through the session", await wait { row("Documenti") != nil && row("old.bin") != nil })

        guard let table, let coordinator = table.coordinator,
              let documents = row("Documenti"), let old = row("old.bin") else {
            check("table ready", false); return
        }

        // Drop from the Finder onto the folder row: validated as a copy.
        let external = FakeDrag(urls: [source])
        let copyOperation = coordinator.tableView(table, validateDrop: external, proposedRow: documents,
                                                  proposedDropOperation: .on)
        check("Finder drop validates as copy", copyOperation == .copy, "\(copyOperation.rawValue)")
        check("Finder drop accepted", coordinator.tableView(table, acceptDrop: external, row: documents,
                                                            dropOperation: .on))
        let copied = await idle(model)
        check("copy completes", copied && model.status.hasPrefix(
            L("Copy completed and verified: \("") in \("").").components(separatedBy: ":")[0]), model.status)

        // Internal drag of a row onto a folder: validated as a move.
        guard let writer = coordinator.tableView(table, pasteboardWriterForRow: old) as? NSPasteboardItem,
              let folderRow = row("Documenti"), let selfRow = row("Documenti") else {
            check("drag source", false); return
        }
        let internalDrag = FakeDrag(items: [writer])
        let moveOperation = coordinator.tableView(table, validateDrop: internalDrag, proposedRow: folderRow,
                                                  proposedDropOperation: .on)
        check("row drag validates as move", moveOperation == .move, "\(moveOperation.rawValue)")
        // A folder dropped onto itself is refused.
        if let folderWriter = coordinator.tableView(table, pasteboardWriterForRow: selfRow) as? NSPasteboardItem {
            let onto = coordinator.tableView(table, validateDrop: FakeDrag(items: [folderWriter]),
                                             proposedRow: selfRow, proposedDropOperation: .on)
            check("folder onto itself refused", onto == [], "\(onto.rawValue)")
        }
        check("row drop accepted", coordinator.tableView(table, acceptDrop: internalDrag, row: folderRow,
                                                         dropOperation: .on))
        let moved = await idle(model)
        check("move completes", moved && model.status.hasPrefix(L("Moved 1 item")), model.status)
        check("moved row gone", await wait { row("old.bin") == nil })

        // Quick Look of an image inside the copied folder, through the session.
        model.go(to: "Documenti/" + source.lastPathComponent)
        guard await wait(until: { row("foto 1.png") != nil }), let photo = row("foto 1.png") else {
            check("copied folder listed", false); return
        }
        table.selectRowIndexes([photo], byExtendingSelection: false)
        table.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        table.window?.makeFirstResponder(table)
        table.toggleQuickLook()
        let shown = await wait(20) { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }
        check("Quick Look shows the exported file", shown && model.quickLookItems.count == 1 &&
              FileManager.default.fileExists(atPath: model.quickLookItems[0].path),
              model.quickLookItems.first?.path ?? "none")
        if shown { QLPreviewPanel.shared().orderOut(nil) }

        let preview = model.quickLookItems.first
        if let preview {
            check("preview is read-only", access(preview.path, W_OK) != 0)
            do {
                try Data("must not replace preview".utf8).write(to: preview, options: .atomic)
                check("preview denies atomic replacement", false)
            } catch {
                check("preview denies atomic replacement", true)
            }
        }
        let saved = source.deletingLastPathComponent().appendingPathComponent("exported-copy.txt")
        if let session = model.session {
            let exported = await Task.detached { session.export("Documenti/old.bin", to: saved) }.value
            check("editable copy exported outside preview cache", exported)
            if exported { try? Data("local edits survive".utf8).write(to: saved) }
        }

        model.endEditing()
        let ended = await wait { model.session == nil && !model.sessionChanging }
        let remounted = await wait { model.record?.mountURL != nil }
        check("session ends and remounts", ended && remounted)
        check("editable copy survives session cleanup",
              (try? Data(contentsOf: saved)) == Data("local edits survive".utf8))
        check("preview cache removed", preview.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }

    private static func recovery(_ model: BrowserModel, source: URL) async {
        model.beginEditing()
        check("recovery inspection completes", await idle(model))
        check("recovery refusal has exact reason", model.recoveryIssue?.reason == "both-names-missing")
        check("write actions disabled", !model.canWrite)
        check("journal visible for salvage", await wait { row(".OpenHDD-journal") != nil })
        model.selection = ["old.bin"]
        check("readable file can be exported", model.canExportSelection)
        let saved = source.deletingLastPathComponent().appendingPathComponent("salvaged.bin")
        if let session = model.session {
            let exported = await Task.detached { session.export("old.bin", to: saved) }.value
            check("readable file saved despite refusal", exported)
        }
        let report = model.recoveryReport() ?? ""
        check("report includes expected paths and reason", report.contains("/missing-old.bin") &&
              report.contains("both-names-missing") && report.contains(model.recoveryIssue?.explanation ?? "MISSING"))
        try? report.write(to: source.deletingLastPathComponent().appendingPathComponent("recovery-report.txt"),
                          atomically: true, encoding: .utf8)
        model.recheckRecovery()
        check("recheck finishes without unlocking", await idle(model) && !model.canWrite)
        // SwiftUI publishes the new state before AppKit renders the next frame.
        table?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: 500_000_000)
        if ProcessInfo.processInfo.environment["OPENHDD_UI_EVIDENCE"] != nil,
           let window = table?.window {
            // NSView caching can omit SwiftUI's composited layers.
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber),
                source.deletingLastPathComponent().appendingPathComponent("recovery-ui.png").path]
            do {
                try capture.run()
                capture.waitUntilExit()
                check("capture recovery window", capture.terminationStatus == 0)
            }
            catch { check("capture recovery window", false, error.localizedDescription) }
        }
        model.endEditing()
        check("refused session closes normally", await wait { model.session == nil && !model.sessionChanging })
        check("report remains available after session", model.recoveryReport() != nil && !model.canWrite)
        check("salvaged file survives cleanup", FileManager.default.fileExists(atPath: saved.path))
    }
}

/// Minimal dragging info carrying file URLs or OpenHDD row items.
final class FakeDrag: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard

    init(urls: [URL] = [], items: [NSPasteboardItem] = []) {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("openhdd-selftest-\(UUID().uuidString)"))
        pasteboard.clearContents()
        if !urls.isEmpty { pasteboard.writeObjects(urls as [NSURL]) }
        if !items.isEmpty {
            let copies = items.map { item -> NSPasteboardItem in
                let copy = NSPasteboardItem()
                for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                return copy
            }
            pasteboard.writeObjects(copies)
        }
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
#endif
