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
