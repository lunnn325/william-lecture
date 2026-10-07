import Foundation

extension SessionStore {
    // Only UUID tombstones survive permanent deletion; no classroom content is retained.
    private func deletionMarker(_ id: UUID) -> URL {
        root.appendingPathComponent(".deleted", isDirectory: true).appendingPathComponent(id.uuidString)
    }
    func isDeleted(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: deletionMarker(id).path) }
    func checkedFolder(_ id: UUID) throws -> URL {
        let directory = folder(id)
        guard directory.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
            throw WLFailure.message("课堂文件路径无效")
        }
        return directory
    }
    func requireSession(_ id: UUID) throws {
        let directory = try checkedFolder(id)
        guard !isDeleted(id), FileManager.default.fileExists(atPath: directory.appendingPathComponent("session.json").path) else {
            throw WLFailure.message("课堂记录已删除或不存在")
        }
    }
    public func sessionMetadata(_ id: UUID) throws -> LectureSession {
        try requireSession(id)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let session = try decoder.decode(LectureSession.self, from: Data(contentsOf: folder(id).appendingPathComponent("session.json")))
        guard session.id == id else { throw WLFailure.message("课堂记录身份不匹配") }
        return session
    }
    private func requireStopped(_ session: LectureSession) throws {
        guard [.stopped, .recovered].contains(session.state) else { throw WLFailure.message("请先结束录课并等待保存完成") }
    }
    /// The actor fences every writer before removing any files. Repeating a deletion is safe.
    public func deleteSession(_ id: UUID) throws {
        try prepare()
        let directory = try checkedFolder(id)
        if !isDeleted(id) {
            try requireStopped(sessionMetadata(id))
            let marker = deletionMarker(id), parent = marker.deletingLastPathComponent()
            guard parent.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
                throw WLFailure.message("删除标记路径无效")
            }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try Data().write(to: marker, options: .atomic)
        }
        discardIndexes(for: id)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    /// A durable state prevents recovery, stale metadata and audio exports undoing cleanup.
    @discardableResult public func clearAudio(_ id: UUID) throws -> LectureSession {
        var session = try sessionMetadata(id); try requireStopped(session)
        session.audioStorage = .clearing; session.audioFiles = []; try save(session)
        let directory = try checkedFolder(id)
        for location in [directory, directory.appendingPathComponent("Exports", isDirectory: true)] {
            let expected = location == directory ? directory.resolvingSymlinksInPath() : directory.resolvingSymlinksInPath().appendingPathComponent("Exports", isDirectory: true)
            guard location.resolvingSymlinksInPath() == expected else {
                throw WLFailure.message("录音清理路径无效")
            }
            guard FileManager.default.fileExists(atPath: location.path) else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let ext = file.pathExtension.lowercased()
                guard ext == "caf" || ext == "m4a" else { continue }
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory != true else { continue }
                // Remove an audio symlink itself, never traverse it.
                try FileManager.default.removeItem(at: file)
            }
        }
        session.audioStorage = .cleared; try save(session)
        if var document = try content(id) {
            document.updatedAt = Date(); _ = try saveContent(document)
        }
        try log(Diagnostic("audio_cleared", offset: session.duration), session: id)
        return session
    }
    public func exportDirectory(_ id: UUID, audio: Bool = false) throws -> URL {
        let session = try sessionMetadata(id)
        if audio && !session.allowsAudioUse { throw WLFailure.message("录音已清理，无法导出音频") }
        let directory = folder(id).appendingPathComponent("Exports", isDirectory: true)
        guard directory.resolvingSymlinksInPath().deletingLastPathComponent() == folder(id).resolvingSymlinksInPath() else {
            throw WLFailure.message("导出文件路径无效")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
    /// Called before queue recovery, including an interrupted removal with partial files left.
    func recoverLibraryCleanup() throws -> [String] {
        var issues: [String] = []
        let markers = root.appendingPathComponent(".deleted", isDirectory: true)
        if FileManager.default.fileExists(atPath: markers.path) {
            guard markers.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
                throw WLFailure.message("删除标记路径无效")
            }
            for marker in try FileManager.default.contentsOfDirectory(at: markers, includingPropertiesForKeys: nil) {
                guard let id = UUID(uuidString: marker.lastPathComponent) else { continue }
                do { try deleteSession(id) } catch { issues.append("部分已删除文件尚未清理：\(error.localizedDescription)") }
            }
        }
        for session in try sessions() where session.audioStorage == .clearing {
            do { _ = try clearAudio(session.id) } catch { issues.append("录音清理未完成：\(error.localizedDescription)") }
        }
        return issues
    }
}
