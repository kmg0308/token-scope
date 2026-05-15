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
        isCancelled: () -> Bool = { false }
    ) -> ScanResult {
        guard !isCancelled() else { return ScanResult() }
        let codexFiles = selectedFiles(findCodexFiles(), modifiedAfter: modifiedAfter)
        guard !isCancelled() else { return ScanResult() }
        let claudeFiles = selectedFiles(findClaudeFiles(), modifiedAfter: modifiedAfter)
        var events: [TokenEvent] = []
        var parseErrors = 0

        for file in codexFiles {
            guard !isCancelled() else { break }
            do {
                events.append(contentsOf: try TokenLogParser.parseCodexFile(at: file, isCancelled: isCancelled))
            } catch {
                parseErrors += 1
            }
        }

        for file in claudeFiles {
            guard !isCancelled() else { break }
            do {
                events.append(contentsOf: try TokenLogParser.parseClaudeFile(at: file, isCancelled: isCancelled))
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

    private func selectedFiles(_ files: [URL], modifiedAfter: Date?) -> [URL] {
        let filtered = files.filter { url in
            if let modifiedAfter {
                guard let date = modificationDate(url), date >= modifiedAfter else { return false }
            }
            return true
        }
        return filtered.sorted {
            (modificationDate($0) ?? .distantPast) > (modificationDate($1) ?? .distantPast)
        }
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
