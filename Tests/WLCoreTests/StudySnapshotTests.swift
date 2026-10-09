import XCTest
@testable import WLCore

final class StudySnapshotTests: XCTestCase {
    private let first = UUID(), second = UUID()
    private var sources: [StudySource] {
        [StudySource(id: first, offset: 4, english: "Social cost includes external cost."),
         StudySource(id: second, offset: 65, english: "A tax changes private incentives.")]
    }
    private var snapshot: StudySnapshot {
        StudySnapshot(title: "外部性", overview: "成本与税收。", outline: [
            StudyNode(id: "cost", title: "社会成本", body: "包括外部成本。", segmentIDs: [first], children: [
                StudyNode(id: "tax", title: "税收", body: "改变私人激励。", segmentIDs: [second])
            ])
        ])
    }
    func testSnapshotRoundTripsExistingStudyNodesWithoutChangingSource() throws {
        let result = try JSONDecoder().decode(StudySnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(try result.validated(sources: sources), snapshot)
        XCTAssertEqual(sources[0].english, "Social cost includes external cost.")
    }
    func testRejectsUnknownSourcesDuplicateIDsAndEmptyReferences() throws {
        var bad = snapshot; bad.outline[0].segmentIDs = [UUID()]
        XCTAssertThrowsError(try bad.validated(sources: sources))
        bad = snapshot; bad.outline[0].children[0].id = "cost"
        XCTAssertThrowsError(try bad.validated(sources: sources))
        bad = snapshot; bad.outline[0].children[0].segmentIDs = []
        XCTAssertThrowsError(try bad.validated(sources: sources))
        XCTAssertThrowsError(try snapshot.validated(sources: [], maxNodes: 32))
    }
    func testBoundsRejectOversizedOrOverDeepResponses() throws {
        XCTAssertThrowsError(try snapshot.validated(sources: sources, maxNodes: 1))
        var bad = snapshot
        bad.outline[0].children[0].children = [StudyNode(id: "third", title: "三", segmentIDs: [second], children: [
            StudyNode(id: "fourth", title: "四", segmentIDs: [second])
        ])]
        XCTAssertThrowsError(try bad.validated(sources: sources))
    }
    func testCollapseHidesDescendantsWithoutMutatingContentOrExport() {
        XCTAssertEqual(StudyTree.visibleIDs(snapshot.outline, collapsed: []), ["cost", "tax"])
        XCTAssertEqual(StudyTree.visibleIDs(snapshot.outline, collapsed: ["cost"]), ["cost"])
        XCTAssertEqual(StudyTree.visibleIDs(snapshot.outline, collapsed: ["old-node"]), ["cost", "tax"])
        let text = snapshot.markdown(sources: sources)
        XCTAssertTrue(text.contains("社会成本 · 00:04"))
        XCTAssertTrue(text.contains("税收 · 01:05"))
        XCTAssertTrue(text.contains("改变私人激励。"))
    }
    func testMockManualSummaryCitesActualSnapshotAndEmptyInputDoesNotRequestAPI() async throws {
        let api = Translator(), config = TranslatorConfiguration(mock: true, model: "gpt-5.6-luna", key: nil)
        let result = try await api.summarize(sources, course: "ECON1111", config: config)
        XCTAssertTrue(result.title.contains("[MOCK]"))
        XCTAssertEqual(try result.validated(sources: sources), result)
        XCTAssertEqual(result.outline[0].segmentIDs, [first])
        XCTAssertEqual(result.outline[0].children[0].segmentIDs, [second])
        do { _ = try await api.summarize([], course: "ECON1111", config: config); XCTFail("Empty snapshot must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("暂无可总结内容")) }
    }
}
