import XCTest
@testable import WLCore

final class LiveContextTests: XCTestCase {
    private func finished(_ start: Double, _ english: String) -> TranscriptSegment {
        var row = TranscriptSegment(start: start, end: start + 2, english: english)
        row.status = .completed; row.chinese = "已有中文"; row.gptRevision = row.sourceRevision
        row.completedAt = Date().addingTimeInterval(-20); row.translationUpdate = 1
        return row
    }
    func testWindowControlsOnlyChangePresentation() {
        var state = CaptionWindowPlayback()
        state.setPlaying(false)
        XCTAssertEqual(state.caption(recording: true), "字幕已暂停 · 录音中")
        state.close(userInitiated: true)
        XCTAssertFalse(state.paused); XCTAssertFalse(state.automaticStartAllowed)
        XCTAssertEqual(state.caption(recording: true), "录音中")
        state.openManually(); XCTAssertTrue(state.automaticStartAllowed)
        state.close(userInitiated: false); XCTAssertTrue(state.automaticStartAllowed)
        state.reset(); XCTAssertFalse(state.paused)
    }
    func testLocalCorrectionsDoNotNeedReplacementInsideLiteralQuote() throws {
        let revision = LiveRevision(english: "The marginal cost is high.", chinese: "边际成本很高。", evidence: ["marginal coast"])
        XCTAssertEqual(try revision.validated(source: "The marginal coast is high.", context: "").english, revision.english)
        XCTAssertEqual(try LiveRevision(english: "They are ready.", chinese: "他们准备好了。", evidence: ["They is"])
            .validated(source: "They is ready.", context: "").english, "They are ready.")
        for pair in [("It is not 5%.", "It is 5%."), ("The return is -5%.", "The return is 5%."),
                     ("N = 5", "= 5"), ("Use np.array and CBDC.", "Use np.arange and CBDC.")] {
            XCTAssertThrowsError(try LiveRevision(english: pair.1, chinese: "不应采用", evidence: [pair.0]).validated(source: pair.0, context: ""))
        }
        XCTAssertThrowsError(try LiveRevision(english: "Demand collapses completely.", chinese: "不应采用", evidence: ["The coast is flat."])
            .validated(source: "The coast is flat.", context: "Demand collapses completely."))
    }
    func testMemoryPersistsAcrossReopenAndIsolatedFromAnotherClassroom() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "ECON1111")
        try await store.save(session)
        var source = finished(0, "Marginal social cost includes external costs.")
        try await store.append(source, session: session.id)
        try await store.updateLiveMemory([.init(kind: "term", english: "marginal social cost", chinese: "边际社会成本", quote: "Marginal social cost")], source: source, session: session.id)
        let target = finished(100, "This is the social cost.")
        try await store.append(finished(45, "Earlier English within ninety seconds."), session: session.id)
        try await store.append(target, session: session.id)
        let reopened = SessionStore(root: root)
        let snapshot = try await reopened.liveContext(target, session: session.id)
        XCTAssertTrue(snapshot.text.contains("marginal social cost")); XCTAssertTrue(snapshot.text.contains("within ninety seconds"))
        XCTAssertTrue(snapshot.text.contains(source.id.uuidString)); XCTAssertGreaterThan(snapshot.version, 0)
        let other = LectureSession(course: "FINN2003"); try await store.save(other)
        let empty = try await reopened.liveMemory(other.id); XCTAssertTrue(empty.items.isEmpty)
        source.revision = 2; source.english = "Different original speech."
        try await reopened.append(source, session: session.id)
        let invalid = try await reopened.liveMemory(session.id); XCTAssertTrue(invalid.items.isEmpty)
        let current = try await reopened.liveContextIsCurrent(snapshot, session: session.id); XCTAssertFalse(current)
    }
    func testMemoryBoundsAndUnquotedEntriesAreRejected() {
        var memory = LiveMemory(sessionID: UUID())
        for index in 0..<100 {
            let source = finished(Double(index), "Term\(index) is the current topic.")
            memory.merge([.init(kind: index % 2 == 0 ? "term" : "topic", english: "Term\(index)", chinese: "术语", quote: "Term\(index)")],
                         source: source, at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertLessThanOrEqual(memory.items.filter { $0.value.kind == "term" }.count, 48)
        XCTAssertLessThanOrEqual(memory.items.filter { $0.value.kind == "topic" }.count, 8)
        let before = memory.items
        memory.merge([.init(kind: "term", english: "Invented", chinese: "虚构", quote: "not actually spoken")], source: finished(0, "Original."))
        XCTAssertEqual(memory.items, before)
    }
    func testRecheckMergesLocalFieldsAndRejectsLateRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "ECON1111")
        try await store.save(session)
        var source = finished(0, "The marginal coast is high.")
        let localToken = UUID(); source.localRequestID = localToken
        try await store.append(source, session: session.id)
        let token = UUID(), begunValue = try await store.beginLiveRecheck(source, session: session.id, request: token)
        let begun = try XCTUnwrap(begunValue)
        XCTAssertEqual(begun.displayChinese, source.displayChinese)
        _ = try await store.applyLocal(source, session: session.id, request: localToken, chinese: "本机草稿", at: Date())
        let result = LiveRevision(english: "The marginal cost is high.", chinese: "边际成本很高。", evidence: ["marginal coast"])
        let mergedValue = try await store.finishLiveRecheck(begun, session: session.id, request: token, result: result, contextVersion: 2)
        let merged = try XCTUnwrap(mergedValue)
        XCTAssertEqual(merged.localChinese, "本机草稿"); XCTAssertEqual(merged.english, source.english)
        XCTAssertEqual(merged.displayEnglish, result.english); XCTAssertEqual(merged.finalChinese, result.chinese)
        XCTAssertEqual(merged.liveContextVersion, 2)
        let replay = try await store.finishLiveRecheck(begun, session: session.id, request: token, result: result, contextVersion: 2)
        XCTAssertNil(replay)
        var changed = merged; changed.revision = 2; changed.english = "Different sentence."; changed.liveRecheckRequestID = UUID()
        try await store.append(changed, session: session.id)
        let stale = try await store.finishLiveRecheck(begun, session: session.id, request: token, result: result, contextVersion: 2)
        XCTAssertNil(stale)
    }
    func testRecheckDelayNewContextAndOneAttemptLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "ECON1111"), now = Date()
        try await store.save(session)
        var source = finished(0, "Earlier sentence."); source.completedAt = now
        try await store.append(source, session: session.id)
        try await store.append(finished(10, "New context."), session: session.id)
        let early = try await store.liveRecheckCandidates(session.id, now: now.addingTimeInterval(7)); XCTAssertTrue(early.isEmpty)
        let ready = try await store.liveRecheckCandidates(session.id, now: now.addingTimeInterval(9)); XCTAssertEqual(ready.count, 1)
        _ = try await store.beginLiveRecheck(source, session: session.id, request: UUID())
        let retried = try await store.liveRecheckCandidates(session.id, now: now.addingTimeInterval(10)); XCTAssertTrue(retried.isEmpty)
        let reopened = SessionStore(root: root); _ = try await reopened.recover()
        let restored = try await reopened.segments(session.id)
        XCTAssertEqual(restored.first?.finalChinese, source.finalChinese); XCTAssertNil(restored.first?.liveRecheckRequestID)
        XCTAssertEqual(restored.first?.liveRecheckedRevision, source.sourceRevision)
    }
    @MainActor func testWorkerRechecksWithLaterContextWithoutBlankingOrMovingReadingPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "ECON1111")
        try await store.save(session)
        let source = finished(0, "The marginal coast is high.")
        try await store.append(source, session: session.id)
        let next = TranscriptSegment(start: 5, end: 7, english: "Marginal cost means an additional cost.")
        try await store.append(next, session: session.id)
        var feed = CaptionFeed(); feed.merge([source, next]); feed.suspend()
        let done = expectation(description: "Context pair published")
        let worker = TranslationWorker(store: store, config: .init(mock: false, model: "fake", key: nil), session: session,
            operation: { row, _ in try LiveRevision(english: row.english, chinese: "后文中文").encoded() },
            recheckOperation: { rows, context in
                XCTAssertTrue(context.contains(next.english)); XCTAssertEqual(rows.count, 1)
                let persisted = try await store.segments(session.id)
                XCTAssertEqual(persisted.first?.finalChinese, "已有中文")
                return [source.id: LiveRevision(english: "The marginal cost is high.", chinese: "边际成本很高。", evidence: ["marginal coast"])]
            }, recheckDelay: 0, recheckInterval: 0)
        worker.onUpdate = { row in
            feed.merge([row])
            if row.id == source.id && row.finalChinese == "边际成本很高。" { done.fulfill() }
        }
        worker.kick(); await fulfillment(of: [done], timeout: 3); await worker.waitForCancellation()
        XCTAssertFalse(feed.following); XCTAssertEqual(feed.rows.first?.displayEnglish, "The marginal cost is high.")
        XCTAssertEqual(feed.rows.last?.id, next.id); XCTAssertEqual(worker.resourceCounts.requests, 0)
    }
    @MainActor func testFailedRecheckKeepsPairAndClearsRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "ECON1111")
        try await store.save(session)
        let source = finished(0, "Earlier original.")
        try await store.append(source, session: session.id); try await store.append(finished(5, "Later original."), session: session.id)
        let requested = expectation(description: "Fake disconnected recheck")
        let worker = TranslationWorker(store: store, config: .init(mock: false, model: "fake", key: nil), session: session,
            operation: { _, _ in "unused" }, recheckOperation: { _, _ in requested.fulfill(); throw URLError(.notConnectedToInternet) },
            recheckDelay: 0, recheckInterval: 0)
        worker.kick(); await fulfillment(of: [requested], timeout: 3); await worker.waitForCancellation()
        let rows = try await store.segments(session.id)
        XCTAssertEqual(rows.first?.finalChinese, source.finalChinese); XCTAssertEqual(rows.first?.displayEnglish, source.displayEnglish)
        XCTAssertNil(rows.first?.liveRecheckRequestID)
    }
    func testCorruptOptionalMemoryDoesNotBlockContextAndOldJSONStillDecodes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root), session = LectureSession(course: "ECON1111"), source = finished(0, "Original.")
        try await store.save(session); try await store.append(source, session: session.id)
        try Data("broken optional memory".utf8).write(to: store.folder(session.id).appendingPathComponent("live-context.json"))
        let snapshot = try await store.liveContext(source, session: session.id); XCTAssertEqual(snapshot.version, 0)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: JSONEncoder().encode(source))
        XCTAssertNil(decoded.liveRecheckedRevision); XCTAssertEqual(decoded.english, source.english)
    }
    func testDeletedClassroomRejectsLateRecheckAndMemoryWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        var session = LectureSession(course: "ECON1111"); session.state = .stopped
        try await store.save(session)
        let source = finished(0, "Marginal cost is high.")
        try await store.append(source, session: session.id)
        let token = UUID(), value = try await store.beginLiveRecheck(source, session: session.id, request: token)
        let begun = try XCTUnwrap(value)
        try await store.deleteSession(session.id)
        let late = try await store.finishLiveRecheck(begun, session: session.id, request: token,
            result: LiveRevision(english: source.english, chinese: "迟到中文"), contextVersion: 1)
        XCTAssertNil(late)
        try await store.updateLiveMemory([.init(kind: "term", english: "Marginal cost", chinese: "边际成本", quote: "Marginal cost")], source: source, session: session.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(session.id).path))
    }
}
