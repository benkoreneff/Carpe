import AppKit

enum ScreenCaptureError: LocalizedError {
    case toolFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .toolFailed(let status): "screencapture failed (exit code \(status))."
        }
    }
}

/// Runs the system's interactive region picker and hands back a temporary PNG.
/// Both variants return nil when the selection is cancelled with Esc, and the
/// caller deletes the file.
enum ScreenCapturer {
    static let tool = URL(fileURLWithPath: "/usr/sbin/screencapture")

    // MARK: - Through the clipboard (default)

    /// `screencapture -i -x -c`, then moves the image from the clipboard into a
    /// temp file and puts the previous clipboard contents back.
    ///
    /// Why not let screencapture write the file itself: before saving a file it
    /// asks Spotlight about it five times. When Spotlight is slow to answer,
    /// each query takes ten seconds and the capture stalls for almost a
    /// minute. Clipboard mode makes no such queries.
    static func captureRegionViaClipboard(
        pasteboard: NSPasteboard = .general,
        runTool: () async throws -> Void = { try await run(tool, ["-i", "-x", "-c"]) }
    ) async throws -> URL? {
        let previous = PasteboardSnapshot(pasteboard)
        let countBefore = pasteboard.changeCount

        try await runTool()

        // Esc leaves the clipboard exactly as it was.
        guard pasteboard.changeCount != countBefore else { return nil }
        // Changed, but not to an image: the user copied something meanwhile.
        // That is theirs, so leave it alone.
        guard let png = pasteboard.data(forType: .png) else { return nil }

        previous.restore(to: pasteboard)
        let file = temporaryFile()
        try png.write(to: file, options: .atomic)
        return file
    }

    // MARK: - Straight to a file

    /// `screencapture -i -x <file>`. Simpler, and leaves the clipboard alone,
    /// but subject to the Spotlight stall described above.
    static func captureRegionToFile(
        runTool: (URL) async throws -> Void = { try await run(tool, ["-i", "-x", $0.path]) }
    ) async throws -> URL? {
        let file = temporaryFile()
        try await runTool(file)
        // screencapture exits 0 either way; a cancelled selection leaves no file.
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    // MARK: - Helpers

    private static func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Carpe-\(UUID().uuidString).png")
    }

    /// Runs a tool and waits for it to exit.
    static func run(_ tool: URL, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard process.terminationStatus == 0 else {
            throw ScreenCaptureError.toolFailed(process.terminationStatus)
        }
    }
}

/// Everything on a pasteboard, copied out so it can be written back later.
struct PasteboardSnapshot {
    private let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.filter { !$0.isEmpty }.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: entry.type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
