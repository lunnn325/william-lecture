import Foundation

public struct LiveMemoryUpdate: Codable, Sendable, Equatable {
    public var kind: String
    public var english: String
    public var chinese: String
    public var quote: String
    public init(kind: String, english: String, chinese: String, quote: String) {
        self.kind = kind; self.english = english; self.chinese = chinese; self.quote = quote
    }
}

public struct LiveMemoryItem: Codable, Sendable, Equatable {
    public var value: LiveMemoryUpdate
    public var segmentID: UUID
    public var revision: Int
    public var source: String
    public var at: Date
}

public struct LiveMemory: Codable, Sendable {
    public var sessionID: UUID
    public var version: Int = 0
    public var items: [LiveMemoryItem] = []
    public init(sessionID: UUID) { self.sessionID = sessionID }
    public mutating func retainValid(in rows: [UUID: TranscriptSegment]) {
        items = items.filter { item in
            guard let row = rows[item.segmentID], row.sourceRevision == item.revision, row.english == item.source else { return false }
            return row.english.localizedCaseInsensitiveContains(item.value.quote) ||
                row.finalEnglish?.localizedCaseInsensitiveContains(item.value.quote) == true
        }
        bound()
    }
    public mutating func merge(_ updates: [LiveMemoryUpdate], source: TranscriptSegment, at: Date = Date()) {
        for update in updates.prefix(2) {
            let value = LiveMemoryUpdate(kind: update.kind, english: update.english.trimmingCharacters(in: .whitespacesAndNewlines),
                chinese: update.chinese.trimmingCharacters(in: .whitespacesAndNewlines), quote: update.quote.trimmingCharacters(in: .whitespacesAndNewlines))
            guard ["topic", "term"].contains(value.kind), !value.english.isEmpty, value.english.count <= 100,
                  value.chinese.count <= 120, value.quote.count >= 3, value.quote.count <= 160,
                  source.english.localizedCaseInsensitiveContains(value.quote) || source.finalEnglish?.localizedCaseInsensitiveContains(value.quote) == true,
                  source.english.localizedCaseInsensitiveContains(value.english) || source.finalEnglish?.localizedCaseInsensitiveContains(value.english) == true else { continue }
            let key = value.english.lowercased()
            items.removeAll { $0.value.kind == value.kind && $0.value.english.lowercased() == key }
            items.append(.init(value: value, segmentID: source.id, revision: source.sourceRevision, source: source.english, at: at))
            version += 1
        }
        bound()
    }
    private mutating func bound() {
        items.sort { $0.at > $1.at }
        var topics = 0, terms = 0, count = 0
        items = items.filter { item in
            let size = item.value.english.count + item.value.chinese.count + item.value.quote.count + 100
            guard count + size <= 6000 else { return false }
            if item.value.kind == "topic" { guard topics < 8 else { return false }; topics += 1 }
            else { guard terms < 48 else { return false }; terms += 1 }
            count += size; return true
        }
    }
}

public struct LiveContextSource: Sendable {
    public var id: UUID
    public var revision: Int
    public var english: String
}

public struct LiveContextSnapshot: Sendable {
    public var sessionID: UUID
    public var version: Int
    public var text: String
    public var sources: [LiveContextSource]
}

public struct LiveRevisionRejection: Error, LocalizedError, Sendable {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { "实时修订未采用：\(reason)" }
}
