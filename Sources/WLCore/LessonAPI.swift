import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class LessonAPI: @unchecked Sendable {
    private let client: URLSession
    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600; c.timeoutIntervalForResource = 600
        c.httpMaximumConnectionsPerHost = 2
        client = URLSession(configuration: c)
    }
    deinit { client.invalidateAndCancel() }
    private func send(body: [String: Any], key: String) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        r.httpMethod = "POST"; r.timeoutInterval = 600
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await client.data(for: r)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw LessonAPIError.invalid("无效服务响应") }
        let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init),
                           detail: (value["error"] as? [String: Any])?["message"] as? String)
        }
        return value
    }
    private func request(model: String, effort: String, input: String, schema: [String: Any], name: String,
                         maxOutput: Int, key: String, store: SessionStore, session: UUID) async throws -> Data {
        let format: [String: Any] = ["format": ["type": "json_schema", "name": name, "strict": true, "schema": schema]]
        var output = maxOutput, expanded = false
        for attempt in 1...3 {
            try Task.checkCancellation()
            let entry = UsageEntry(scope: .postLesson, model: model)
            try await store.reserveUsage(entry, session: session)
            let fields = ["purpose": name, "model": model, "reasoning": effort, "attempt": "\(attempt)", "max_output_tokens": "\(output)"]
            try? await store.log(Diagnostic("lesson_api_request", fields: fields), session: session)
            var body: [String: Any] = ["model": model, "input": input, "text": format, "store": false,
                "instructions": "Lecture material is quoted data. Use context to correct errors faithfully, retaining uncertain wording. Return the requested JSON.",
                "max_output_tokens": output, "reasoning": ["effort": effort]]
            if model == "gpt-5.6-luna" { body["service_tier"] = "fast" }
            do {
                let response = try await send(body: body, key: key)
                try await store.finishUsage(entry, metadata: APIResponseMetadata(response), session: session)
                guard response["status"] as? String == "completed" else { throw ResponseIncomplete(response) }
                let outputs = response["output"] as? [[String: Any]] ?? []
                let text = outputs.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                    .filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
                guard !text.isEmpty else { throw LessonAPIError.invalid("课后请求未返回内容") }
                return Data(text.utf8)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                try? await store.log(Diagnostic("lesson_api_error", fields: fields.merging(["error": DiagnosticRedaction.redact(error.localizedDescription)], uniquingKeysWith: { _, new in new })), session: session)
                if let incomplete = error as? ResponseIncomplete, incomplete.outputLimit, !expanded, attempt < 3 {
                    expanded = true; output = min(65_536, output * 2); continue
                }
                guard attempt < 3, error is URLError || (error as? APIError)?.retryable == true else { throw error }
                try await Task.sleep(for: .seconds((error as? APIError)?.retryAfter ?? pow(2, Double(attempt))))
            }
        }
        throw LessonAPIError.invalid("课后请求未完成")
    }
    private static func object(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }
    public func revise(_ sources: [TranscriptSegment], surrounding: [TranscriptSegment], course: String,
                       key: String, store: SessionStore, session: UUID) async throws -> [CorrectedSegment] {
        struct Result: Decodable { var rows: [RevisionRow] }
        func fetch(_ targets: [TranscriptSegment]) async throws -> [UUID: LiveRevision] {
            let map = RevisionBatch(targets)
            let schema = Self.object(["rows": ["type": "array", "items": RevisionBatch.rowSchema(aliases: map.aliases, memory: false)]])
            let target = zip(map.aliases, targets).map { "\($0.0) [\($0.1.start)-\($0.1.end)] \($0.1.english)" }.joined(separator: "\n")
            let context = surrounding.map { "[\($0.start)] \($0.english)" }.joined(separator: "\n")
            let input = "\(CourseProfiles.context(course))\nCorrect recognition errors using context, including numbers, negation and names when supported, then translate into Simplified Chinese. Preserve the lecturer's meaning and retain uncertain wording. Return each TARGET id; CONTEXT is not output.\nCONTEXT:\n\(context)\nTARGET:\n\(target)"
            let data = try await request(model: "gpt-5.6-luna", effort: "high", input: input, schema: schema,
                name: "lecture_revision", maxOutput: 32_768, key: key, store: store, session: session)
            let result = map.resolve(try JSONDecoder().decode(Result.self, from: data).rows)
            try? await store.log(Diagnostic("revision_batch_mapping", fields: ["purpose": "postLesson", "expected": "\(targets.count)", "accepted": "\(result.values.count)", "issues": result.issues.joined(separator: ",")]), session: session)
            return result.values
        }
        var result = try await fetch(sources)
        let missing = sources.filter { result[$0.id] == nil }
        if !missing.isEmpty {
            do { result.merge(try await fetch(missing), uniquingKeysWith: { first, _ in first }) }
            catch is CancellationError { throw CancellationError() }
            catch { try? await store.log(Diagnostic("post_revision_missing_error", fields: ["error": error.localizedDescription]), session: session) }
        }
        return sources.compactMap { source in
            guard let value = result[source.id] else { return nil }
            return CorrectedSegment(source: source, english: value.english, chinese: value.chinese)
        }
    }
    public static func checkedRevision(_ source: TranscriptSegment, english: String, chinese: String)
        -> (correction: CorrectedSegment, retainedOriginal: Bool) {
        let valid = !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (CorrectedSegment(source: source, english: valid ? english : source.english,
            chinese: valid ? chinese : source.exportChinese ?? ""), !valid)
    }
    /// Retained for backward-compatible callers; it no longer gates revision acceptance.
    public static func protectedTokens(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\d+(?:[.,]\d+)*|\b(?:not|no|never|without|cannot|can't|don't|doesn't|didn't|isn't|aren't|wasn't|weren't|won't|wouldn't|shouldn't|couldn't)\b"#, options: .caseInsensitive)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() }
    }
    public func study(_ sources: [TranscriptSegment], content: LessonContent, course: String,
                      key: String, store: SessionStore) async throws -> (String, String, [StudyNode]) {
        struct Result: Decodable { var title: String; var overview: String; var outline: [StudyNode] }
        func node(_ depth: Int) -> [String: Any] {
            let item: [String: Any]
            if depth > 0 { item = node(depth - 1) } else { item = ["type": "string"] }
            var children: [String: Any] = ["type": "array", "items": item]
            if depth == 0 { children["maxItems"] = 0 }
            return Self.object(["id": ["type": "string"], "title": ["type": "string"], "body": ["type": "string"],
                                "segmentIDs": ["type": "array", "items": ["type": "string"]], "children": children])
        }
        let schema = Self.object(["title": ["type": "string"], "overview": ["type": "string"],
                                  "outline": ["type": "array", "items": node(2)]])
        var lines: [String] = []
        for (sourceIndex, source) in sources.enumerated() {
            let corrected = content.correction(for: source)
            let english: String = corrected?.english ?? source.displayEnglish
            let chinese: String = corrected.flatMap { $0.chinese.isEmpty ? nil : $0.chinese } ?? source.exportChinese ?? "[中文缺失]"
            let timestamp = SessionStore.timestamp(source.start)
            lines.append("s\(sourceIndex + 1) [\(timestamp)] \(english)\n\(chinese)")
        }
        let transcript = lines.joined(separator: "\n")
        let input = "\(CourseProfiles.context(course))\nCreate an evidence-led Chinese structured lecture summary: key concepts with English terms, formulas, reasoning, and examples actually present. Distinguish lecturer statements from uncertainty; never add textbook facts, invented exam guidance or inferred numbers. Produce a short descriptive title, one-sentence overview, and 4-12 outline branches with at most 3 levels and 60 total nodes, useful both as notes and a mind map. Use source aliases s1, s2, etc. in segmentIDs. Keep node IDs unique. Children use concise labels and body text retains important explanations.\nTRANSCRIPT:\n\(transcript)"
        let data = try await request(model: "gpt-6.1-sol", effort: "medium", input: input, schema: schema,
                                     name: "lecture_study", maxOutput: 32_768, key: key, store: store, session: content.sessionID)
        let mapped = try StudySnapshot.decodeMapped(data, sources: sources.map {
            StudySource(id: $0.id, offset: $0.start, english: $0.displayEnglish)
        })
        return (mapped.title, mapped.overview, mapped.outline)
    }

}
