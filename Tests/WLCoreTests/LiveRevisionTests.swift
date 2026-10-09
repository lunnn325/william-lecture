import XCTest
@testable import WLCore

final class LiveRevisionTests: XCTestCase {
    func testStandaloneWordsUseContextWithoutSkippingFullSentences() {
        for word in ["right", "what?", "why", "really", "well", "Oh!", "exactly", "thank you"] {
            XCTAssertTrue(ShortUtterance.localOnly(word)); XCTAssertNotNil(ShortUtterance.draft(word))
        }
        XCTAssertEqual(ShortUtterance.draft("right", context: "Turn to the"), "右边")
        XCTAssertEqual(ShortUtterance.draft("right?", context: "Demand falls."), "对吗？")
        for sentence in ["What is marginal cost?", "Why would demand fall?", "Turn right at the bank.", "Well, I cannot agree.", "No, the rate is 5%."] {
            XCTAssertFalse(ShortUtterance.localOnly(sentence)); XCTAssertNil(ShortUtterance.draft(sentence))
        }
    }
    func testRevisionRequiresLiteralEvidenceAndPreservesProtectedContent() throws {
        let source = "The marginal coast is 5."
        let context = "Marginal cost is the additional cost."
        let revision = LiveRevision(english: "The marginal cost is 5.", chinese: "边际成本是 5。", evidence: ["Marginal cost"])
        XCTAssertEqual(try revision.validated(source: source, context: context), revision)
        XCTAssertThrowsError(try revision.validated(source: source, context: "Unrelated lecture."))
        XCTAssertThrowsError(try LiveRevision(english: "The marginal cost is 6.", chinese: "6", evidence: ["Marginal cost"]).validated(source: source, context: context))
        XCTAssertThrowsError(try LiveRevision(english: "It is available.", chinese: "可用", evidence: ["available"]).validated(source: "It is not available.", context: "available"))
        XCTAssertThrowsError(try LiveRevision(english: "The demand curve declines.", chinese: "下降", evidence: ["Marginal cost"]).validated(source: "The coast is flat.", context: context))
        XCTAssertEqual(try LiveRevision(english: "Can…", chinese: "能……").validated(source: "Can…", context: "").english, "Can…")
    }
    func testStreamingDecodesOnlyChineseIncludingSplitEscapes() throws {
        XCTAssertNil(LiveRevision.streamedChinese(#"{"engli"#))
        XCTAssertEqual(LiveRevision.streamedChinese(#"{"chinese":"中\u65"#), "中")
        XCTAssertEqual(LiveRevision.streamedChinese(#"{"chinese":"中\u6587"#), "中文")
        XCTAssertEqual(LiveRevision.streamedChinese(#"{"chinese":"中文\"引文\"","english":"Source"}"#), "中文\"引文\"")
        let revision = LiveRevision(english: "Why?", chinese: "为什么？")
        XCTAssertEqual(try LiveRevision.unpack(revision.encoded()), revision)
        XCTAssertNil(try LiveRevision.unpack("普通译文"))
    }
    @MainActor func testWorkerPublishesAtomicPairAndKeepsRawExportAndStaleGuards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "ECON1111")
        try await store.save(session)
        var context = TranscriptSegment(start: 0, end: 2, english: "Marginal cost is the additional cost.")
        context.status = .completed; context.chinese = "边际成本是新增成本。"
        var source = TranscriptSegment(start: 3, end: 5, english: "The marginal coast is 5.")
        source.localEnabled = true; source.localChinese = "本机草稿"; source.localSourceText = source.english; source.localRevision = 1
        for row in [context, source] { try await store.append(row, session: session.id) }
        let upgraded = expectation(description: "Atomic corrected English and Chinese update")
        let worker = TranslationWorker(store: store, config: .init(mock: false, model: "fake", key: nil), session: session,
            operation: { _, _ in try LiveRevision(english: "The marginal cost is 5.", chinese: "边际成本是 5。", evidence: ["Marginal cost"]).encoded() })
        worker.onUpdate = { row in
            if row.finalChinese != nil {
                XCTAssertEqual(row.english, source.english)
                XCTAssertEqual(row.displayEnglish, "The marginal cost is 5."); XCTAssertEqual(row.displayChinese, "边际成本是 5。")
                upgraded.fulfill()
            }
        }
        worker.kick(); await fulfillment(of: [upgraded], timeout: 3); await worker.waitForCancellation()
        let rows = try await store.segments(session.id), final = try XCTUnwrap(rows.last)
        var feed = CaptionFeed(); feed.merge([final]); feed.suspend(); feed.merge([source])
        XCTAssertFalse(feed.following); XCTAssertEqual(feed.rows.last?.displayEnglish, final.displayEnglish)
        let daily = try await store.export(session.id, language: .bilingual, markdown: false)
        let raw = try await store.export(session.id, language: .english, markdown: false, original: true)
        XCTAssertTrue(try String(contentsOf: daily, encoding: .utf8).contains("The marginal cost is 5."))
        XCTAssertTrue(try String(contentsOf: raw, encoding: .utf8).contains("The marginal coast is 5."))
        var changed = final; changed.english = "The marginal coast is 7."; changed.revision = 2; changed.status = .pending
        try await store.append(changed, session: session.id)
        let late = try await store.applyGPT(source, session: session.id, request: UUID(), status: .completed,
            chinese: "旧响应", revisedEnglish: "The marginal cost is 5.")
        XCTAssertNil(late); XCTAssertEqual(changed.displayEnglish, changed.english)
        let reopened = SessionStore(root: root)
        let persisted = try await reopened.segments(session.id)
        XCTAssertEqual(persisted.last?.english, changed.english)
    }
    func testUnsafePostLessonPairFallsBackWithoutBlockingStudy() {
        var source = TranscriptSegment(start: 0, end: 2, english: "It is not 5%.")
        source.localChinese = "不是 5%。"; source.localSourceText = source.english; source.localRevision = 1
        let rejected = LessonAPI.checkedRevision(source, english: "It is 6%.", chinese: "是 6%。")
        XCTAssertTrue(rejected.retainedOriginal); XCTAssertEqual(rejected.correction.english, source.english)
        XCTAssertEqual(rejected.correction.chinese, source.validLocalChinese)
        XCTAssertTrue(rejected.correction.matches(source))
        let accepted = LessonAPI.checkedRevision(source, english: "It is not 5%.", chinese: "不是 5%。")
        XCTAssertFalse(accepted.retainedOriginal)
    }
    func testManualSummaryUsageDeduplicatesAndDoesNotUsePostLessonBudget() {
        var entry = UsageEntry(scope: .manualSummary, model: "fake")
        entry.responseID = "summary-1"; entry.usage = .init(input: 100, output: 20, total: 120)
        var unknown = UsageEntry(scope: .manualSummary, model: "fake"); unknown.reserved = 500
        let totals = UsageTotals([entry, entry, unknown])
        XCTAssertEqual(totals.total, 120); XCTAssertEqual(totals.manualSummary, 120)
        XCTAssertEqual(totals.chargedPostLesson, 0); XCTAssertEqual(totals.unknown, 1)
    }
    func testAppearanceDefaultsAndOldJSONCompatibility() throws {
        XCTAssertEqual(CaptionSize.standard.englishPoints, 17); XCTAssertEqual(CaptionSize.standard.chinesePoints, 22)
        XCTAssertLessThan(CaptionSize.small.chinesePoints, CaptionSize.large.chinesePoints)
        XCTAssertLessThan(CaptionTone.light.opacity, CaptionTone.dark.opacity)
        let source = TranscriptSegment(start: 0, end: 1, english: "Original")
        let oldData = try JSONEncoder().encode(source)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("gptEnglish"))
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: oldData)
        XCTAssertEqual(decoded.displayEnglish, "Original"); XCTAssertNil(decoded.finalEnglish)
    }
}
