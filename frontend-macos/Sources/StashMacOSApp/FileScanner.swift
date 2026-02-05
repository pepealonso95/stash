import Foundation

struct FileScanner {
    static func scan(rootURL: URL) -> [FileItem] {
        var files: [FileItem] = []
        let rootPath = rootURL.path
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) else {
            return files
        }

        for case let url as URL in enumerator {
            if url.path.contains("/.stash/") || url.lastPathComponent == ".stash" {
                if url.lastPathComponent == ".stash" {
                    enumerator.skipDescendants()
                }
                continue
            }

            let relative = url.path.replacingOccurrences(of: rootPath + "/", with: "")
            if relative.isEmpty {
                continue
            }

            let depth = relative.split(separator: "/").count - 1
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            files.append(
                FileItem(
                    id: relative,
                    relativePath: relative,
                    name: url.lastPathComponent,
                    depth: max(depth, 0),
                    isDirectory: isDirectory
                )
            )
        }

        files.sort {
            if $0.isDirectory != $1.isDirectory {
                return $0.isDirectory && !$1.isDirectory
            }
            return $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
        }

        return files
    }
}
