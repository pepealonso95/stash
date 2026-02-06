import Foundation

struct FileScanner {
    static func scan(rootURL: URL) -> [FileItem] {
        var files: [FileItem] = []
        let normalizedRoot = rootURL.standardizedFileURL
        let rootPath = normalizedRoot.path
        let resolvedRootPath = normalizedRoot.resolvingSymlinksInPath().path
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
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

            let relative = relativePath(
                for: url,
                rootPath: rootPath,
                resolvedRootPath: resolvedRootPath
            )
            if relative.isEmpty {
                continue
            }

            let depth = relative.split(separator: "/").count - 1
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDirectory = values?.isDirectory ?? false
            let parentRelativePath = relativeParentPath(for: relative)
            let fileSize = values?.fileSize.map(Int64.init)
            let modifiedAt = values?.contentModificationDate
            files.append(
                FileItem(
                    id: relative,
                    relativePath: relative,
                    name: url.lastPathComponent,
                    depth: max(depth, 0),
                    isDirectory: isDirectory,
                    parentRelativePath: parentRelativePath,
                    pathExtension: url.pathExtension.lowercased(),
                    fileSizeBytes: isDirectory ? nil : fileSize,
                    modifiedAt: modifiedAt
                )
            )
        }

        files.sort(by: compareHierarchy)

        return files
    }

    static func signature(for files: [FileItem]) -> Int {
        var hasher = Hasher()
        for item in files {
            hasher.combine(item.relativePath)
            hasher.combine(item.isDirectory)
            hasher.combine(item.fileSizeBytes)
            hasher.combine(item.modifiedAt?.timeIntervalSince1970 ?? 0)
        }
        return hasher.finalize()
    }

    private static func compareHierarchy(lhs: FileItem, rhs: FileItem) -> Bool {
        let lhsComponents = lhs.relativePath.split(separator: "/").map(String.init)
        let rhsComponents = rhs.relativePath.split(separator: "/").map(String.init)

        let lhsParent = lhsComponents.dropLast().joined(separator: "/")
        let rhsParent = rhsComponents.dropLast().joined(separator: "/")

        if lhsParent != rhsParent {
            return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }

        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory && !rhs.isDirectory
        }

        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func relativeParentPath(for relativePath: String) -> String {
        let parts = relativePath.split(separator: "/")
        guard parts.count > 1 else {
            return ""
        }
        return parts.dropLast().joined(separator: "/")
    }

    private static func relativePath(for url: URL, rootPath: String, resolvedRootPath: String) -> String {
        let candidatePaths = [
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().standardizedFileURL.path,
            url.path,
        ]
        for candidate in candidatePaths {
            if let trimmed = trimPrefix(candidate, prefix: rootPath), !trimmed.isEmpty {
                return trimmed
            }
            if let trimmed = trimPrefix(candidate, prefix: resolvedRootPath), !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }

    private static func trimPrefix(_ value: String, prefix: String) -> String? {
        if value == prefix {
            return ""
        }
        let normalizedPrefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
        guard value.hasPrefix(normalizedPrefix) else {
            return nil
        }
        return String(value.dropFirst(normalizedPrefix.count))
    }
}
