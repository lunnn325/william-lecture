import Foundation

/// A manual summary is an immutable, source-linked snapshot, not a live task.
public struct StudySource: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var offset: Double
    public var english: String
    public init(id: UUID, offset: Double, english: String) {
        self.id = id; self.offset = offset; self.english = english
    }
}

public struct StudySnapshot: Codable, Sendable, Equatable {
    public var title: String
    public var overview: String
    public var outline: [StudyNode]
    public init(title: String, overview: String, outline: [StudyNode]) {
        self.title = title; self.overview = overview; self.outline = outline
    }
    public func validated(sources: [StudySource], maxNodes: Int = 32) throws -> Self {
        let allowed = Set(sources.map(\.id))
        let nodes = StudyTree.flatten(outline)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !nodes.isEmpty, nodes.count <= maxNodes, Set(nodes.map(\.id)).count == nodes.count,
              StudyTree.depth(outline) <= 3,
              nodes.allSatisfy({ !$0.id.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !$0.segmentIDs.isEmpty && Set($0.segmentIDs).isSubset(of: allowed) }) else {
            throw WLFailure.message("摘要结构或来源不完整，请重试")
        }
        return self
    }
    public func markdown(sources: [StudySource]) -> String {
        let times = Dictionary(sources.map { ($0.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var lines = ["# \(title)", "", overview, ""]
        func append(_ nodes: [StudyNode], depth: Int) {
            for node in nodes {
                let timestamps = node.segmentIDs.compactMap { times[$0] }.map(SessionStore.readingTime)
                lines.append("\(String(repeating: "  ", count: depth))- \(node.title)\(timestamps.isEmpty ? "" : " · " + timestamps.joined(separator: " / "))")
                if !node.body.isEmpty { lines.append("\(String(repeating: "  ", count: depth + 1))\(node.body)") }
                append(node.children, depth: depth + 1)
            }
        }
        append(outline, depth: 0)
        return lines.joined(separator: "\n")
    }
    /// Same native StudyNode representation as saved lessons; no generated UI code.
    public static var schema: [String: Any] {
        func object(_ fields: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": fields, "required": Array(fields.keys).sorted(), "additionalProperties": false]
        }
        func node(_ depth: Int) -> [String: Any] {
            var children: [String: Any] = ["type": "array", "items": depth > 0 ? node(depth - 1) : ["type": "string"]]
            if depth == 0 { children["maxItems"] = 0 }
            return object(["id": ["type": "string"], "title": ["type": "string"], "body": ["type": "string"],
                           "segmentIDs": ["type": "array", "items": ["type": "string"]], "children": children])
        }
        return object(["title": ["type": "string"], "overview": ["type": "string"],
                       "outline": ["type": "array", "items": node(2)]])
    }
}

public enum StudyTree {
    public static func flatten(_ nodes: [StudyNode]) -> [StudyNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }
    public static func depth(_ nodes: [StudyNode]) -> Int {
        nodes.map { 1 + depth($0.children) }.max() ?? 0
    }
    public static func visibleIDs(_ nodes: [StudyNode], collapsed: Set<String>) -> [String] {
        nodes.flatMap { [$0.id] + (collapsed.contains($0.id) ? [] : visibleIDs($0.children, collapsed: collapsed)) }
    }
}
