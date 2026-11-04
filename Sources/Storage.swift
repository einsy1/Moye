import Foundation
final class DraftStore {
    let directory: URL
    var file: URL { directory.appendingPathComponent("workspace.json") }
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.neil.moye/v1.1", isDirectory: true)
    }
    // Runs before any workspace write. Keep the entire old data directory intact.
    @discardableResult
    func backupBeforeUpgrade(version: String) throws -> URL? {
        let fm = FileManager.default
        let marker = directory.appendingPathComponent(".backup-before-" + version)
        if let existing = try? String(contentsOf: marker, encoding: .utf8), fm.fileExists(atPath: existing) { return nil }
        guard fm.fileExists(atPath: directory.path) else { return nil }
        let backups = directory.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let destination = backups.appendingPathComponent("pre-\(version)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.copyItem(at: directory, to: destination)
            try destination.path.write(to: marker, atomically: true, encoding: .utf8)
            return destination
        } catch {
            // Incomplete copies are never treated as a valid rollback point.
            try? fm.removeItem(at: destination)
            throw error
        }
    }
    func load() -> [String: Any]? {
        for url in [file, directory.appendingPathComponent("workspace.previous.json")] {
            if let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], value["docs"] is [[String: Any]] { return value }
        }
        return nil
    }
    func save(_ value: [String: Any]) throws {
        guard value["docs"] is [[String: Any]] else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        if let existing = try? Data(contentsOf: file), existing == data { return }
        if let previous = try? Data(contentsOf: file), let parsed = try? JSONSerialization.jsonObject(with: previous) as? [String: Any], parsed["docs"] is [[String: Any]] { try previous.write(to: directory.appendingPathComponent("workspace.previous.json"), options: .atomic) }
        try data.write(to: file, options: .atomic)
    }
    func archive(_ doc: [String: Any]) throws {
        let folder = directory.appendingPathComponent("Deleted Drafts", isDirectory:true)
        try FileManager.default.createDirectory(at:folder, withIntermediateDirectories:true)
        let name = (doc["name"] as? String ?? "未命名文稿").components(separatedBy:CharacterSet(charactersIn:"/\\:")).joined(separator:"_").prefix(60)
        let stamp = Int(Date().timeIntervalSince1970)
        try JSONSerialization.data(withJSONObject:doc).write(to:folder.appendingPathComponent("\(name)-\(stamp)-\(UUID().uuidString).json"), options:.atomic)
        if let files = try? FileManager.default.contentsOfDirectory(at:folder, includingPropertiesForKeys:[.contentModificationDateKey]).filter({ $0.pathExtension == "json" }), files.count > 50 {
            let sorted = files.sorted { ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for old in sorted.dropFirst(50) { try? FileManager.default.removeItem(at:old) }
        }
    }
    func latestDeleted() throws -> [String: Any]? {
        let folder = directory.appendingPathComponent("Deleted Drafts", isDirectory:true)
        guard FileManager.default.fileExists(atPath:folder.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at:folder, includingPropertiesForKeys:[.contentModificationDateKey]).filter { $0.pathExtension == "json" }
        guard let url = files.sorted(by: { ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }).first else { return nil }
        return try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String: Any]
    }
    func loadConfig() -> NASConfig? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("nas.json")) else { return nil }
        return try? JSONDecoder().decode(NASConfig.self, from: data)
    }
    func saveConfig(_ config: NASConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("nas.json"), options: .atomic)
    }
}

// A close decision acknowledges only this exact text, never future edits.
enum ClosePolicy {
    static func needsPrompt(_ doc: [String: Any], acknowledgedText: String? = nil) -> Bool {
        let text = doc["text"] as? String ?? ""
        if acknowledgedText == text { return false }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && doc["path"] == nil && doc["nasRemote"] == nil { return false }
        let localDirty = doc["path"] != nil && text != doc["savedText"] as? String
        let remoteDirty = doc["nasRemote"] != nil && text != doc["nasSavedText"] as? String
        let unnamed = doc["path"] == nil && doc["nasRemote"] == nil
        return localDirty || remoteDirty || unnamed || doc["pendingUpload"] != nil
    }
}


enum LocalFileError: LocalizedError {
    case tooLarge, invalidUTF8, conflict
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "文稿超过 10 MB，请拆分后打开。"
        case .invalidUTF8: return "文件不是有效的 UTF-8 文本。"
        case .conflict: return "原文件已被其他软件修改、移动或删除，或缺少保存基准。你的编辑仍在草稿中，请另存副本。"
        }
    }
}
enum LocalFileIO {
    static let maxBytes = 10_000_000
    static func read(_ url: URL) throws -> String {
        // Read at most limit+1, including when a file grows after the size check.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= maxBytes else { throw LocalFileError.tooLarge }
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw LocalFileError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw LocalFileError.invalidUTF8 }
        return text
    }
    static func write(_ text: String, to url: URL, protectingOriginal: Bool, expectedText: String?) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?, operationError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                if protectingOriginal {
                    guard let expected = expectedText,
                          let diskText = try? read(target), diskText == expected else { throw LocalFileError.conflict }
                }
                try text.write(to: target, atomically: true, encoding: .utf8)
            } catch { operationError = error }
        }
        if let error = operationError { throw error }
        if let error = coordinationError { throw error }
    }
}
