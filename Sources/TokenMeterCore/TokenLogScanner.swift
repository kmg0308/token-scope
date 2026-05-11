import Foundation

public final class TokenLogScanner: @unchecked Sendable {
    private let homeDirectory: URL
    private let fileManager: FileManager

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    public func scan(
        modifiedAfter: Date? = nil,
        maxFilesPerSource: Int? = nil,
        maxFileBytes: Int? = nil
    ) -> ScanResult {
        let codexFiles = selectedFiles(findCodexFiles(), modifiedAfter: modifiedAfter, maxFiles: maxFilesPerSource, maxFileBytes: maxFileBytes)
        let claudeFiles = selectedFiles(findClaudeFiles(), modifiedAfter: modifiedAfter, maxFiles: maxFilesPerSource, maxFileBytes: maxFileBytes)
        var events: [TokenEvent] = []
        var parseErrors = 0

        for file in codexFiles {
            do {
                events.append(contentsOf: try TokenLogParser.parseCodexFile(at: file))
            } catch {
                parseErrors += 1
            }
        }

        for file in claudeFiles {
            do {
                events.append(contentsOf: try TokenLogParser.parseClaudeFile(at: file))
            } catch {
                parseErrors += 1
            }
        }

        return ScanResult(
            events: events.sorted { $0.timestamp < $1.timestamp },
            codexFileCount: codexFiles.count,
            claudeFileCount: claudeFiles.count,
            parseErrorCount: parseErrors,
            scannedAt: Date()
        )
    }

    public func findCodexFiles() -> [URL] {
        let roots = [
            homeDirectory.appendingPathComponent(".codex/sessions"),
            homeDirectory.appendingPathComponent(".codex/archived_sessions")
        ]
        return roots.flatMap { jsonlFiles(under: $0) }
    }

    public func findClaudeFiles() -> [URL] {
        jsonlFiles(under: homeDirectory.appendingPathComponent(".claude/projects"))
    }

    private func jsonlFiles(under root: URL) -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return files
    }

    private func selectedFiles(_ files: [URL], modifiedAfter: Date?, maxFiles: Int?, maxFileBytes: Int?) -> [URL] {
        let filtered = files.filter { url in
            if let modifiedAfter {
                guard let date = modificationDate(url), date >= modifiedAfter else { return false }
            }
            if let maxFileBytes, let size = fileSize(url), size > maxFileBytes {
                return false
            }
            return true
        }
        let sorted = filtered.sorted {
            (modificationDate($0) ?? .distantPast) > (modificationDate($1) ?? .distantPast)
        }
        if let maxFiles {
            return Array(sorted.prefix(maxFiles))
        }
        return sorted
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
