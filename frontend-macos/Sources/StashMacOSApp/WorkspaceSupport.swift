import Foundation

enum FileKindDetector {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    private static let csvExtensions: Set<String> = ["csv", "tsv"]
    private static let jsonExtensions: Set<String> = ["json", "jsonc"]
    private static let yamlExtensions: Set<String> = ["yaml", "yml"]
    private static let xmlExtensions: Set<String> = ["xml", "xsd", "xsl", "plist"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "tiff", "svg", "ico"]
    private static let pdfExtensions: Set<String> = ["pdf"]
    private static let officeExtensions: Set<String> = ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key"]
    private static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go", "java", "kt", "kts", "py", "rb", "js", "jsx", "ts", "tsx",
        "php", "cs", "scala", "lua", "sh", "bash", "zsh", "fish", "ps1", "sql", "r", "dart", "elm", "ex", "exs", "clj", "groovy",
        "toml", "ini", "cfg", "conf", "env", "dockerfile", "makefile", "mk", "gradle", "cmake", "sln", "xcodeproj", "pbxproj", "lock"
    ]
    private static let textExtensions: Set<String> = ["txt", "rtf", "log", "text", "req", "rst", "adoc", "cfg", "conf", "ini"]

    static func detect(pathExtension: String, isBinary: Bool) -> FileKind {
        let ext = pathExtension.lowercased()
        if markdownExtensions.contains(ext) {
            return .markdown
        }
        if csvExtensions.contains(ext) {
            return .csv
        }
        if jsonExtensions.contains(ext) {
            return .json
        }
        if yamlExtensions.contains(ext) {
            return .yaml
        }
        if xmlExtensions.contains(ext) {
            return .xml
        }
        if imageExtensions.contains(ext) {
            return .image
        }
        if pdfExtensions.contains(ext) {
            return .pdf
        }
        if officeExtensions.contains(ext) {
            return .office
        }
        if codeExtensions.contains(ext) {
            return .code
        }
        if textExtensions.contains(ext) {
            return .text
        }

        if isBinary {
            return .binary
        }

        if ext.isEmpty {
            return .text
        }
        return .text
    }
}

enum WorkspacePathValidator {
    static func isInsideProject(candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    static func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let ancestorPath = ancestor.standardizedFileURL.path
        return candidatePath == ancestorPath || candidatePath.hasPrefix(ancestorPath + "/")
    }
}

enum ExplorerClickResolver {
    static let doubleClickThresholdSeconds: TimeInterval = 0.22

    static var previewDelayNanoseconds: UInt64 {
        UInt64(doubleClickThresholdSeconds * 1_000_000_000)
    }

    static func isDoubleClick(
        currentPath: String,
        previousPath: String?,
        previousTapAt: Date,
        currentTapAt: Date,
        threshold: TimeInterval = doubleClickThresholdSeconds
    ) -> Bool {
        guard let previousPath, previousPath == currentPath else {
            return false
        }
        return currentTapAt.timeIntervalSince(previousTapAt) <= threshold
    }
}

enum TextFileDecoder {
    private static let fallbackEncodings: [String.Encoding] = [
        .utf8,
        .utf16,
        .utf16LittleEndian,
        .utf16BigEndian,
        .unicode,
        .windowsCP1252,
        .isoLatin1,
    ]

    static func decode(data: Data, forceText: Bool) -> (text: String, isBinary: Bool) {
        if data.isEmpty {
            return ("", false)
        }

        if let text = decodeUsingKnownBOM(data: data) {
            return (text, false)
        }

        for encoding in fallbackEncodings {
            if let text = String(data: data, encoding: encoding),
               looksReasonablyTextual(text, forceText: forceText)
            {
                return (text, false)
            }
        }

        if forceText {
            // Keep editable formats usable even with uncommon encodings.
            return (String(decoding: data, as: UTF8.self), false)
        }

        return ("", true)
    }

    private static func decodeUsingKnownBOM(data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data, encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian)
        }
        return nil
    }

    private static func looksReasonablyTextual(_ value: String, forceText: Bool) -> Bool {
        if value.isEmpty {
            return true
        }
        if forceText {
            return true
        }
        let replacementCount = value.reduce(into: 0) { count, character in
            if character == "\u{FFFD}" {
                count += 1
            }
        }
        let ratio = Double(replacementCount) / Double(value.count)
        return ratio < 0.15
    }
}

enum CSVCodec {
    static func parse(_ content: String) -> [[String]] {
        if content.isEmpty {
            return [[""]]
        }

        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var inQuotes = false

        var index = content.startIndex
        while index < content.endIndex {
            let char = content[index]

            if inQuotes {
                if char == "\"" {
                    let next = content.index(after: index)
                    if next < content.endIndex, content[next] == "\"" {
                        cell.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    cell.append(char)
                }
            } else {
                switch char {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(cell)
                    cell = ""
                case "\n":
                    row.append(cell)
                    rows.append(row)
                    row = []
                    cell = ""
                case "\r":
                    row.append(cell)
                    rows.append(row)
                    row = []
                    cell = ""
                    let next = content.index(after: index)
                    if next < content.endIndex, content[next] == "\n" {
                        index = next
                    }
                default:
                    cell.append(char)
                }
            }

            index = content.index(after: index)
        }

        if !row.isEmpty || !cell.isEmpty || content.hasSuffix(",") {
            row.append(cell)
            rows.append(row)
        }

        if rows.isEmpty {
            return [[""]]
        }
        return rows
    }

    static func encode(_ rows: [[String]]) -> String {
        rows
            .map { row in
                row.map(escapeCell).joined(separator: ",")
            }
            .joined(separator: "\n")
    }

    private static func escapeCell(_ cell: String) -> String {
        let escaped = cell.replacingOccurrences(of: "\"", with: "\"\"")
        let needsQuotes = escaped.contains(",") || escaped.contains("\n") || escaped.contains("\r") || escaped.contains("\"")
        if needsQuotes {
            return "\"\(escaped)\""
        }
        return escaped
    }
}
