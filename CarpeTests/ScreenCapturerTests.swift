import AppKit
import Foundation
import Testing

/// Clipboard tests use a private named pasteboard, never the real clipboard.
@Suite struct ScreenCapturerTests {
    static func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CarpeTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    static func pngData() throws -> Data {
        let url = try ImagePreparerTests.makePNG(width: 64, height: 48)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    // MARK: - Clipboard mode

    @Test func clipboardCaptureReturnsTheImageAndRestoresTheClipboard() async throws {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("what the user had copied", forType: .string)
        let png = try Self.pngData()

        let file = try #require(await ScreenCapturer.captureRegionViaClipboard(pasteboard: pasteboard) {
            // What `screencapture -c` does.
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
        })
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(try Data(contentsOf: file) == png)
        #expect(pasteboard.string(forType: .string) == "what the user had copied")
        #expect(pasteboard.data(forType: .png) == nil)
    }

    @Test func clipboardCaptureRestoresAnEmptyClipboardToEmpty() async throws {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let png = try Self.pngData()

        let file = try #require(await ScreenCapturer.captureRegionViaClipboard(pasteboard: pasteboard) {
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
        })
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    @Test func cancelledClipboardCaptureReturnsNilAndTouchesNothing() async throws {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("untouched", forType: .string)
        let countBefore = pasteboard.changeCount

        // Esc: screencapture exits without writing to the clipboard.
        let file = try await ScreenCapturer.captureRegionViaClipboard(pasteboard: pasteboard) {}

        #expect(file == nil)
        #expect(pasteboard.changeCount == countBefore)
        #expect(pasteboard.string(forType: .string) == "untouched")
    }

    @Test func somethingElseCopiedDuringSelectionIsLeftAlone() async throws {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("old", forType: .string)

        let file = try await ScreenCapturer.captureRegionViaClipboard(pasteboard: pasteboard) {
            pasteboard.clearContents()
            pasteboard.setString("copied by the user meanwhile", forType: .string)
        }

        #expect(file == nil)
        #expect(pasteboard.string(forType: .string) == "copied by the user meanwhile")
    }

    @Test func snapshotRoundTripsSeveralTypes() {
        let pasteboard = Self.makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setString("<b>rich</b>", forType: .html)
        item.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.custom"))
        pasteboard.writeObjects([item])

        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("something else", forType: .string)
        snapshot.restore(to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "plain")
        #expect(pasteboard.string(forType: .html) == "<b>rich</b>")
        #expect(pasteboard.data(forType: NSPasteboard.PasteboardType("com.example.custom")) == Data([1, 2, 3]))
    }

    // MARK: - File mode

    @Test func fileCaptureReturnsTheWrittenFile() async throws {
        let png = try Self.pngData()
        let file = try #require(await ScreenCapturer.captureRegionToFile { try png.write(to: $0) })
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == png)
    }

    @Test func cancelledFileCaptureReturnsNil() async throws {
        #expect(try await ScreenCapturer.captureRegionToFile { _ in } == nil)
    }

    // MARK: - Running the tool

    @Test func runWaitsForTheToolAndReportsFailure() async throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("CarpeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        try await ScreenCapturer.run(shell, ["-c", "sleep 0.2; touch '\(marker.path)'"])
        #expect(FileManager.default.fileExists(atPath: marker.path))

        await #expect(throws: ScreenCaptureError.self) {
            try await ScreenCapturer.run(shell, ["-c", "exit 3"])
        }
    }
}
