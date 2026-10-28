#if OPENHDD_LOCAL && OPENHDD_UI_SELFTEST
import AppKit

/// Test build only: walks the app through the scenes shown in the README and
/// captures each window with screencapture. Driven by Scripts/readme-screenshots.sh,
/// which prepares localized disk images; never compiled into the normal app.
@MainActor
enum ReadmeShots {
    struct Plan: Decodable {
        let archive: String
        let holiday: String
        let portraits: String
        let videos: String
        let work: String
        let video: String
        let output: String
    }

    static func run(_ model: BrowserModel, plan url: URL) async {
        guard let data = try? Data(contentsOf: url),
              let plan = try? JSONDecoder().decode(Plan.self, from: data) else {
            fail("cannot read plan \(url.path)"); return
        }
        let output = URL(fileURLWithPath: plan.output)
        guard await wait(until: { model.disks.records.contains { $0.name == plan.archive } }),
              let record = model.disks.records.first(where: { $0.name == plan.archive }) else {
            fail("disk \(plan.archive) not listed"); return
        }
        model.disks.selected = record.bsdName
        model.diskChanged()

        // 1. The disk, read-only, with a folder selected.
        guard await wait(until: { row(plan.work) != nil }) else { fail("root not listed"); return }
        await capture(selecting: plan.work, to: output.appendingPathComponent("01-browser.png"))

        // 2. A folder of photos.
        model.go(to: plan.holiday)
        guard await wait(until: { (table?.numberOfRows ?? 0) >= 6 && row(plan.work) == nil }) else {
            fail("folder not listed"); return
        }
        await capture(selectingRow: 1, to: output.appendingPathComponent("02-folder.png"))

        // 3. The same folder with editing active.
        model.beginEditing()
        guard await wait(until: { model.editingHere }), await idle(model),
              await wait(until: { (table?.numberOfRows ?? 0) >= 6 }) else {
            fail("edit session did not start"); return
        }
        await capture(selectingRow: 1, to: output.appendingPathComponent("03-edit-session.png"))

        // 4. A large copy in progress.
        model.go(to: plan.videos)
        guard await idle(model) else { fail("videos folder not listed"); return }
        model.copy([URL(fileURLWithPath: plan.video)], into: plan.videos)
        guard await wait(until: { (model.progress ?? 0) > 0.3 }) else { fail("copy did not progress"); return }
        await capture(selecting: nil, to: output.appendingPathComponent("04-copy-progress.png"))
        guard await idle(model) else { fail("copy did not finish"); return }

        // 5. The confirmation before deleting a folder.
        model.go(to: "")
        guard await wait(until: { row(plan.portraits) != nil }) else { fail("root not listed again"); return }
        let alert = model.deleteConfirmation([plan.portraits])
        alert.layout()
        alert.window.center()
        alert.window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 800_000_000)
        shoot(alert.window, to: output.appendingPathComponent("05-delete-confirm.png"))
        alert.window.orderOut(nil)

        model.endEditing()
        _ = await wait { model.session == nil && !model.sessionChanging }
        print("README shots written to \(output.path)")
    }

    private static var table: BrowserTableView? { UISelfTest.table }

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("README shots failed: \(message)\n".utf8))
    }

    private static func wait(_ seconds: Double = 60, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private static func idle(_ model: BrowserModel) async -> Bool {
        await wait(120) { model.running == nil && model.queue.isEmpty && model.preparing == nil &&
            !model.sessionChanging && !model.loading }
    }

    private static func row(_ name: String) -> Int? {
        guard let table, let coordinator = table.coordinator else { return nil }
        return (0..<coordinator.numberOfRows(in: table)).first { coordinator.entryName(at: $0) == name }
    }

    private static func capture(selecting name: String?, to file: URL) async {
        await capture(selectingRow: name.flatMap(row), to: file)
    }

    /// Selects a row (as a user click would), brings the window forward so it
    /// is drawn active, lets AppKit render, then captures it without shadow.
    private static func capture(selectingRow index: Int?, to file: URL) async {
        guard let table, let window = table.window else { fail("no window"); return }
        if let index { table.selectRowIndexes([index], byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(table)
        try? await Task.sleep(nanoseconds: 800_000_000)
        shoot(window, to: file)
    }

    private static func shoot(_ window: NSWindow, to file: URL) {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        do {
            try capture.run()
            capture.waitUntilExit()
            if capture.terminationStatus != 0 { fail("screencapture \(file.lastPathComponent)") }
        } catch { fail("screencapture: \(error.localizedDescription)") }
    }
}
#endif
