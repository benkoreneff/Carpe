import Foundation

/// `ShotCal --extract <image> [--model <id>]`
///
/// Sends one image through the same extraction the hotkey uses and prints
/// Claude's JSON plus the resolved dates. The API key comes from the Keychain,
/// or from ANTHROPIC_API_KEY when the Keychain has none.
struct CommandLineTool {
    var imagePath: String
    var model: String

    init?(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--extract") else { return nil }
        imagePath = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
        if let modelFlag = arguments.firstIndex(of: "--model"), arguments.indices.contains(modelFlag + 1) {
            model = arguments[modelFlag + 1]
        } else {
            model = Preferences.modelID
        }
    }

    /// Returns the process exit code.
    func run() async -> Int32 {
        guard !imagePath.isEmpty else {
            return fail("usage: ShotCal --extract <image> [--model <id>]")
        }
        let key = Keychain.get(.anthropicAPIKey) ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        guard !key.isEmpty else {
            return fail("No API key: save one in ShotCal's Settings or set ANTHROPIC_API_KEY.")
        }

        do {
            let image = try ImagePreparer.prepare(fileAt: URL(fileURLWithPath: imagePath))
            let now = Date()
            let timeZone = TimeZone.current
            let client = ClaudeClient(apiKey: key, model: model)
            let result = try await client.extractEvents(from: image, now: now, timeZone: timeZone)

            print("# \(model), image sent at \(image.pixelWidth)x\(image.pixelHeight) px"
                + (result.usedStructuredOutputs ? "" : ", plain-JSON fallback"))
            print(JSONFormatting.pretty(result.rawJSON))

            let resolver = EventDateResolver(now: now, timeZone: timeZone)
            for event in result.extraction.events {
                let resolved = try resolver.resolve(event)
                print("# -> \(EventFormatter.line(resolved))" + (resolved.isAllDay ? " (all day)" : ""))
            }
            return 0
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }
}
