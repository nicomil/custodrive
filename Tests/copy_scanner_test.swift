import Foundation

/// Folder merges are detected before copying: only the outermost existing
/// folders are reported, with the name as it is on the disk.
@main
struct CopyScannerTest {
    static func main() throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("custodrive-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("Vacanze")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Giorno 1"),
                                                withIntermediateDirectories: true)
        try Data("a".utf8).write(to: source.appendingPathComponent("Giorno 1/a.txt"))

        func scanned(_ volume: [String: [(name: String, isDirectory: Bool)]]) -> CopyScan {
            var scan = CopyScanner.scan([source], into: "")
            CopyScanner.compare(&scan) { volume[$0] ?? [] }
            return scan
        }
        let fresh = scanned([:])
        precondition(fresh.merging.isEmpty && fresh.problems.isEmpty, "new folder: \(fresh.merging)")

        // Existing folder, other letter case, with an existing subfolder too.
        let merged = scanned(["": [("vacanze", true)], "Vacanze": [("Giorno 1", true)]])
        precondition(merged.merging == ["vacanze"], "merge: \(merged.merging)")
        precondition(merged.problems.isEmpty && merged.existing.isEmpty)

        // A file in the way is a problem, never a merge.
        let blocked = scanned(["": [("Vacanze", false)]])
        precondition(blocked.merging.isEmpty && blocked.problems.count == 1, "\(blocked.problems)")
        print("PASS copy scanner: existing folders reported once for merge, files in the way refused")
    }
}
