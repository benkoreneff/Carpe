import Foundation

enum JSONFormatting {
    /// Indents JSON text for reading while keeping the keys in the order they
    /// were written. (JSONSerialization's pretty printer shuffles them.)
    /// Text that isn't valid JSON is returned unchanged.
    static func pretty(_ json: String) -> String {
        guard (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) != nil else {
            return json
        }

        var output = ""
        var depth = 0
        var inString = false
        var escaped = false

        func newline() {
            output += "\n" + String(repeating: "  ", count: depth)
        }

        for character in json {
            if inString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            switch character {
            case "\"":
                inString = true
                output.append(character)
            case "{", "[":
                output.append(character)
                depth += 1
                newline()
            case "}", "]":
                depth = max(0, depth - 1)
                // Keep empty containers on one line: [] and {}.
                let trimmed = output.trimmingSuffix(while: \.isWhitespace)
                if trimmed.last == "{" || trimmed.last == "[" {
                    output = String(trimmed)
                } else {
                    newline()
                }
                output.append(character)
            case ",":
                output.append(character)
                newline()
            case ":":
                output += ": "
            case _ where character.isWhitespace:
                continue
            default:
                output.append(character)
            }
        }
        return output
    }
}

private extension String {
    func trimmingSuffix(while predicate: (Character) -> Bool) -> Substring {
        var end = endIndex
        while end > startIndex, predicate(self[index(before: end)]) {
            end = index(before: end)
        }
        return self[..<end]
    }
}
