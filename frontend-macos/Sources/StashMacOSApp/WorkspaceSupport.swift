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

        if forceText,
           let utf16Guess = detectLikelyUTF16Encoding(data: data),
           let text = String(data: data, encoding: utf16Guess),
           looksReasonablyTextual(text)
        {
            return (text, false)
        }

        var firstDecodedCandidate: String?
        for encoding in fallbackEncodings {
            guard let text = String(data: data, encoding: encoding) else {
                continue
            }
            if firstDecodedCandidate == nil {
                firstDecodedCandidate = text
            }
            if looksReasonablyTextual(text) {
                return (text, false)
            }
        }

        if forceText {
            // Keep editable formats usable even with uncommon encodings.
            if let firstDecodedCandidate {
                return (firstDecodedCandidate, false)
            }
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

    private static func looksReasonablyTextual(_ value: String) -> Bool {
        if value.isEmpty {
            return true
        }
        var replacementCount = 0
        var nullCount = 0
        var controlCount = 0
        let scalarCount = max(1, value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            let code = scalar.value
            if code == 0xFFFD {
                replacementCount += 1
            }
            if code == 0 {
                nullCount += 1
            }
            if (code < 0x20 && code != 0x09 && code != 0x0A && code != 0x0D) || (code >= 0x7F && code <= 0x9F) {
                controlCount += 1
            }
        }
        let replacementRatio = Double(replacementCount) / Double(scalarCount)
        if replacementRatio > 0.15 {
            return false
        }
        let nullRatio = Double(nullCount) / Double(scalarCount)
        if nullRatio > 0.05 {
            return false
        }
        let controlRatio = Double(controlCount) / Double(scalarCount)
        return controlRatio < 0.2
    }

    private static func detectLikelyUTF16Encoding(data: Data) -> String.Encoding? {
        if data.count < 4 {
            return nil
        }
        let sample = data.prefix(512)
        var evenTotal = 0
        var oddTotal = 0
        var evenZeros = 0
        var oddZeros = 0
        for (index, byte) in sample.enumerated() {
            if index % 2 == 0 {
                evenTotal += 1
                if byte == 0 {
                    evenZeros += 1
                }
            } else {
                oddTotal += 1
                if byte == 0 {
                    oddZeros += 1
                }
            }
        }
        guard evenTotal > 0, oddTotal > 0 else {
            return nil
        }
        let evenZeroRatio = Double(evenZeros) / Double(evenTotal)
        let oddZeroRatio = Double(oddZeros) / Double(oddTotal)
        if oddZeroRatio > 0.35, evenZeroRatio < 0.2 {
            return .utf16LittleEndian
        }
        if evenZeroRatio > 0.35, oddZeroRatio < 0.2 {
            return .utf16BigEndian
        }
        return nil
    }
}

enum CSVCodec {
    static func parse(_ content: String) -> [[String]] {
        let sanitized = normalizeInput(content)
        if sanitized.isEmpty {
            return [[""]]
        }

        let delimiter = detectDelimiter(in: sanitized)
        let primary = parseCore(sanitized, delimiter: delimiter)
        if primary.rows.count > 1 {
            return primary.rows
        }

        // If robust quoted parsing collapses to one row but the raw text has line breaks,
        // fall back to line-wise parsing so users still get a usable grid.
        if containsLineBreaks(sanitized) {
            let fallback = parseLineByLine(sanitized, delimiter: delimiter)
            if fallback.count > 1 {
                return fallback
            }
        }

        if primary.rows.isEmpty {
            return [[""]]
        }
        return primary.rows
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

    private static func normalizeInput(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{0000}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{0085}", with: "\n")
    }

    private static func containsLineBreaks(_ value: String) -> Bool {
        value.contains("\n")
    }

    private static func detectDelimiter(in content: String) -> Character {
        guard let firstLine = content.split(separator: "\n", omittingEmptySubsequences: false).first else {
            return ","
        }

        let candidates: [Character] = [",", ";", "\t", "|"]
        var best: Character = ","
        var bestScore = -1
        let line = String(firstLine)

        for candidate in candidates {
            let score = line.filter { $0 == candidate }.count
            if score > bestScore {
                best = candidate
                bestScore = score
            }
        }
        return best
    }

    private static func parseCore(_ content: String, delimiter: Character) -> (rows: [[String]], endedInQuotes: Bool) {
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
                if char == "\"" {
                    inQuotes = true
                } else if char == delimiter {
                    row.append(cell)
                    cell = ""
                } else if char == "\n" {
                    row.append(cell)
                    rows.append(row)
                    row = []
                    cell = ""
                } else {
                    cell.append(char)
                }
            }

            index = content.index(after: index)
        }

        if !row.isEmpty || !cell.isEmpty || content.last == delimiter {
            row.append(cell)
            rows.append(row)
        }

        if rows.isEmpty {
            rows = [[""]]
        }
        return (rows, inQuotes)
    }

    private static func parseLineByLine(_ content: String, delimiter: Character) -> [[String]] {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let parsed = lines.map { parseSingleLine($0, delimiter: delimiter) }
        return parsed.isEmpty ? [[""]] : parsed
    }

    private static func parseSingleLine(_ line: String, delimiter: Character) -> [String] {
        var cells: [String] = []
        var cell = ""
        var inQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if inQuotes {
                if char == "\"" {
                    let next = line.index(after: index)
                    if next < line.endIndex, line[next] == "\"" {
                        cell.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    cell.append(char)
                }
            } else if char == "\"" {
                inQuotes = true
            } else if char == delimiter {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(char)
            }
            index = line.index(after: index)
        }
        cells.append(cell)
        return cells
    }
}
