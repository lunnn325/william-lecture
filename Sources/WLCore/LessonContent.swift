import Foundation

public enum CourseProfiles {
    public static let courses = ["ECON1111", "FINN2003", "FINN2004", "FINN3001"]
    public static func context(_ course: String) -> String {
        let code = course.uppercased()
        let glossary: String
        if code.contains("ECON1111") {
            glossary = "Economics for Business Decision. externality=外部性; marginal social/private cost=边际社会/私人成本; cap-and-trade=总量控制与交易; public goods=公共物品; common resources=公共资源; free rider=搭便车者; rivalry=竞争性; excludability=排他性; information asymmetry=信息不对称; adverse selection=逆向选择; moral hazard=道德风险. Lemons in a used-car example means 劣质车."
        } else if code.contains("FINN2003") {
            glossary = "Financial Technologies and Innovations. CBDC=央行数字货币; DeFi=去中心化金融; stablecoin=稳定币; payment rails=支付基础设施; wallet=钱包; on/off-ramp=法币与加密资产兑换通道; programmability=可编程性; financial inclusion=金融普惠. Preserve CBDC, DeFi, L2, e-CNY, AML and FX abbreviations."
        } else if code.contains("FINN2004") {
            glossary = "International Finance (general glossary, current teaching scope not verified). exchange rate=汇率; direct/indirect quotation=直接/间接标价法; PPP=购买力平价; CIP/UIP=抛补/未抛补利率平价; forward contract=远期合约; currency swap=货币互换; appreciation/depreciation=升值/贬值. Preserve currency pair, quote direction, units and maturity exactly."
        } else if code.contains("FINN3001") {
            glossary = "Finance Modeling. cash flow=现金流; discount rate=折现率; present value=现值; NPV=净现值; IRR=内部收益率; payback period=投资回收期; indexing/slicing=索引/切片; data cleaning=数据清洗; missing values=缺失值; descriptive statistics=描述性统计. Preserve Python/NumPy/Pandas code, identifiers, formulas, enumerate, np.arange, dtype, .loc, .iloc and PV.sum() verbatim."
        } else { glossary = "General university lecture." }
        return "Course label: \(course). \(glossary) Glossary is terminology guidance, not evidence that the lecturer said something. Never replace a lecturer's claim with textbook knowledge."
    }
}

public struct TokenUsage: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var total: Int
    public init(input: Int, output: Int, total: Int) { self.input = input; self.output = output; self.total = total }
}
public struct APIResponseMetadata: Sendable {
    public var id: String?
    public var usage: TokenUsage?
    public var tier: String?
    public init(_ response: [String: Any]) {
        id = response["id"] as? String; tier = response["service_tier"] as? String
        if let u = response["usage"] as? [String: Any], let i = u["input_tokens"] as? Int,
           let o = u["output_tokens"] as? Int, let t = u["total_tokens"] as? Int, i >= 0, o >= 0, t >= 0 {
            usage = TokenUsage(input: i, output: o, total: t)
        }
    }
}
public enum UsageScope: String, Codable, Sendable { case live, postLesson, lookup, manualSummary }
public struct UsageEntry: Codable, Sendable, Identifiable {
    public var id: UUID
    public var scope: UsageScope
    public var model: String
    public var reserved: Int
    public var responseID: String?
    public var usage: TokenUsage?
    public var tier: String?
    public var at: Date
    public init(scope: UsageScope, model: String, reserved: Int = 0) {
        id = UUID(); self.scope = scope; self.model = model; self.reserved = reserved; at = Date()
    }
}
public struct UsageTotals: Sendable {
    public var live = 0, postLesson = 0, lookup = 0, manualSummary = 0, input = 0, output = 0, unknown = 0
    public var total: Int { live + postLesson + lookup + manualSummary }
    public var chargedPostLesson = 0
    public init(_ entries: [UsageEntry]) {
        var responseIDs = Set<String>()
        for e in entries {
            if let id = e.responseID, !responseIDs.insert(id).inserted { continue }
            if e.scope == .postLesson { chargedPostLesson += e.usage?.total ?? e.reserved }
            guard let u = e.usage else { unknown += 1; continue }
            input += u.input; output += u.output
            switch e.scope {
            case .live: live += u.total
            case .postLesson: postLesson += u.total
            case .lookup: lookup += u.total
            case .manualSummary: manualSummary += u.total
            }
        }
    }
}

public enum LessonProcessingState: String, Codable, Sendable {
    case pending, repairing, revising, generating, completed, waitingForNetwork, needsConfiguration, failed, limitReached
    public var label: String {
        switch self {
        case .pending, .repairing: return "正在整理"
        case .revising: return "翻译处理中"
        case .generating: return "正在生成摘要"
        case .completed: return "已完成"
        case .waitingForNetwork: return "等待网络"
        case .needsConfiguration: return "需要检查设置"
        case .failed: return "处理未完成"
        case .limitReached: return "处理用量已达上限"
        }
    }
    public var automatic: Bool { [.pending, .repairing, .revising, .generating, .waitingForNetwork].contains(self) }
}
public struct CorrectedSegment: Codable, Sendable, Equatable {
    public var id: UUID
    public var revision: Int
    public var sourceEnglish: String
    public var english: String
    public var chinese: String
    public init(source: TranscriptSegment, english: String, chinese: String) {
        id = source.id; revision = source.sourceRevision; sourceEnglish = source.english
        self.english = english; self.chinese = chinese
    }
    public func matches(_ source: TranscriptSegment) -> Bool {
        id == source.id && revision == source.sourceRevision && sourceEnglish == source.english
    }
}
public struct StudyNode: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var body: String
    public var segmentIDs: [UUID]
    public var children: [StudyNode]
    public init(id: String, title: String, body: String = "", segmentIDs: [UUID] = [], children: [StudyNode] = []) {
        self.id = id; self.title = title; self.body = body; self.segmentIDs = segmentIDs; self.children = children
    }
}
public struct LessonContent: Codable, Sendable {
    public var sessionID: UUID
    public var fingerprint: String
    public var state: LessonProcessingState
    public var corrected: [CorrectedSegment]
    public var title: String?
    public var overview: String?
    public var outline: [StudyNode]
    public var error: String?
    public var audioRepairWarning: String?
    public var updatedAt: Date
    public init(sessionID: UUID, segments: [TranscriptSegment]) {
        self.sessionID = sessionID; fingerprint = Self.fingerprint(segments); state = .pending
        corrected = []; outline = []; updatedAt = Date()
    }
    public static func fingerprint(_ segments: [TranscriptSegment]) -> String {
        // Stable across processes and platforms; Swift Hasher is intentionally randomized.
        var hash: UInt64 = 14695981039346656037
        for s in segments.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            for b in "\(s.id)|\(s.sourceRevision)|\(s.start)|\(s.end)|\(s.english)\u{0}".utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        }
        return String(hash, radix: 16)
    }
    public func correction(for source: TranscriptSegment) -> CorrectedSegment? {
        corrected.first { $0.matches(source) }
    }
}

extension SessionStore {
    public func content(_ id: UUID) throws -> LessonContent? {
        try requireSession(id)
        let url = folder(id).appendingPathComponent("content.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = try decoder.decode(LessonContent.self, from: Data(contentsOf: url))
        guard value.sessionID == id else { throw WLFailure.message("课堂内容身份不匹配") }
        return value
    }
    @discardableResult public func saveContent(_ content: LessonContent) throws -> Bool {
        try requireSession(content.sessionID)
        guard !Task.isCancelled, content.fingerprint == LessonContent.fingerprint(try segments(content.sessionID)) else { return false }
        var content = content
        if !(try sessionMetadata(content.sessionID)).allowsAudioUse {
            content.audioRepairWarning = try audioRepairRanges(content.sessionID).isEmpty ? nil : "录音已清理，未补转写的内容无法恢复"
        }
        if let current = try self.content(content.sessionID), current.fingerprint == content.fingerprint,
           current.updatedAt > content.updatedAt { return false }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let url = folder(content.sessionID).appendingPathComponent("content.json")
        try encoder.encode(content).write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        return true
    }
    public func usageEntries(_ id: UUID) throws -> [UsageEntry] {
        try requireSession(id)
        var latest: [UUID: UsageEntry] = [:]
        try JSONLines.scan(UsageEntry.self, at: folder(id).appendingPathComponent("usage.jsonl")) { latest[$0.id] = $0 }
        return latest.values.sorted { $0.at < $1.at }
    }
    public func reserveUsage(_ entry: UsageEntry, session id: UUID) throws {
        try requireSession(id)
        guard entry.reserved >= 0 else { throw WLFailure.message("无效用量预留") }
        if entry.scope == .postLesson {
            guard UsageTotals(try usageEntries(id)).chargedPostLesson + entry.reserved <= 250_000 else {
                throw LessonAPIError.budget
            }
        }
        try JSONLines.append(entry, to: folder(id).appendingPathComponent("usage.jsonl"))
    }
    public func finishUsage(_ entry: UsageEntry, metadata: APIResponseMetadata, session id: UUID) throws {
        try requireSession(id)
        var result = entry; result.responseID = metadata.id; result.usage = metadata.usage; result.tier = metadata.tier
        try JSONLines.append(result, to: folder(id).appendingPathComponent("usage.jsonl"))
    }
    public func rename(_ id: UUID, title: String) throws {
        guard var session = try sessions().first(where: { $0.id == id }) else { return }
        session.title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        try save(session)
    }
    public func usageTotals(_ id: UUID) throws -> UsageTotals { UsageTotals(try usageEntries(id)) }
    public func repairTranslation(_ source: TranscriptSegment, chinese: String, session id: UUID) throws {
        guard !chinese.isEmpty, let current = try translationSnapshot(source, session: id), current.finalChinese == nil else { return }
        let token = UUID()
        guard let begun = try beginGPT(current, session: id, request: token, at: Date()) else { return }
        _ = try applyGPT(begun, session: id, request: token, status: .completed, chinese: chinese, completedAt: Date())
    }
    public func exportStudy(_ id: UUID) throws -> URL {
        guard let content = try content(id), !content.outline.isEmpty else { throw WLFailure.message("摘要尚未完成") }
        var lines = ["# \(content.title ?? "课堂摘要")", content.overview ?? ""]
        let times = Dictionary(uniqueKeysWithValues: try segments(id).map { ($0.id, $0.start) })
        func add(_ nodes: [StudyNode], depth: Int) {
            for n in nodes {
                lines.append("\(String(repeating: "#", count: min(6, depth))) \(n.title)")
                lines.append(n.body)
                let references = n.segmentIDs.compactMap { times[$0].map(Self.timestamp) }
                if !references.isEmpty { lines.append("来源：\(references.joined(separator: "、"))") }
                add(n.children, depth: depth + 1)
            }
        }
        add(content.outline, depth: 2)
        let directory = try exportDirectory(id)
        let url = directory.appendingPathComponent("Study-\(UUID().uuidString).md")
        try lines.joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8); return url
    }
}

public enum LessonAPIError: Error, LocalizedError {
    case budget, invalid(String)
    public var errorDescription: String? {
        switch self { case .budget: return "课后处理已达到 250k token 上限"; case .invalid(let s): return s }
    }
}
