import XCTest
import UIKit

@MainActor final class V1FlowTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    func testLibraryCleanupPlaybackExportAndDetailDeletion() {
        let app = launch(active: false)
        let card = app.buttons["history-10000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.press(forDuration: 1); app.buttons["清理录音"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.buttons["取消"].tap()
        XCTAssertTrue(card.exists); card.tap()
        let play = app.buttons["play-lecture"]; XCTAssertTrue(play.waitForExistence(timeout: 10)); waitEnabled(play); play.tap()
        app.buttons["lesson-menu"].tap(); app.buttons["修改名称"].tap()
        XCTAssertTrue(app.alerts["课堂名称"].waitForExistence(timeout: 5)); app.alerts.buttons["取消"].tap()
        app.buttons["lesson-menu"].tap(); app.buttons["清理录音"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.buttons["清理录音"].tap()
        XCTAssertTrue(app.staticTexts["audio-cleared"].waitForExistence(timeout: 10)); XCTAssertFalse(play.exists)
        XCTAssertTrue(app.staticTexts["caption-english-20000000-0000-0000-0000-000000000001"].exists)
        capture(app, "audio-cleared-detail")
        app.buttons["导出课堂"].tap(); app.buttons["生成导出文件"].tap()
        XCTAssertTrue(app.buttons["分享 / 保存到文件"].waitForExistence(timeout: 40)); app.buttons["完成"].tap()
        app.buttons["lesson-menu"].tap(); app.buttons["删除记录"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.buttons["删除记录"].tap()
        XCTAssertTrue(app.buttons["start-recording"].waitForExistence(timeout: 10)); XCTAssertFalse(card.exists)
    }
    func testLibraryCardDeletionCancellationAndNextRecording() {
        let app = launch(active: false)
        let card = app.buttons["history-10000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.press(forDuration: 1); app.buttons["删除记录"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.buttons["取消"].tap()
        XCTAssertTrue(card.exists)
        card.press(forDuration: 1); app.buttons["删除记录"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.buttons["删除记录"].tap()
        XCTAssertTrue(app.staticTexts["暂无记录"].waitForExistence(timeout: 10)); XCTAssertFalse(card.exists)
        app.buttons["start-recording"].tap()
        XCTAssertTrue(app.buttons["pause-recording"].waitForExistence(timeout: 10))
    }
    func testSelectedSentenceMarkWhileRecording() {
        let app = launch(active: true)
        XCTAssertTrue(app.buttons["pause-recording"].waitForExistence(timeout: 20))
        let oldID = "20000000-0000-0000-0000-000000000017"
        let latestID = "20000000-0000-0000-0000-000000000018"
        if app.images["caption-mark-\(latestID)"].exists { app.buttons["add-note"].tap() }
        let old = app.staticTexts["caption-english-\(oldID)"]
        if !old.isHittable { app.scrollViews["caption-scroll"].swipeDown() }
        XCTAssertTrue(old.isHittable); old.tap()
        app.buttons["add-note"].tap()
        XCTAssertTrue(app.images["caption-mark-\(oldID)"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.images["caption-mark-\(latestID)"].exists)
        XCTAssertTrue(app.staticTexts["录音中"].exists)
    }
    func testReadingMarkNotePauseStopPlaybackAndExport() {
        let app = launch(active: true)
        let pause = app.buttons["pause-recording"]
        XCTAssertTrue(pause.waitForExistence(timeout: 20))
        capture(app, "workspace-light")
        app.buttons["add-note"].tap()
        app.buttons["add-note"].press(forDuration: 1)
        app.buttons["笔记"].tap()
        let editor = app.textViews["note-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.typeText("Review price ceiling")
        app.buttons["保存笔记"].tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5)); pause.tap()
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 5))
        let frozen = app.staticTexts["recording-time"].label
        pause.tap(); XCTAssertTrue(app.staticTexts["录音中"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["recording-time"].label, frozen)
        let scroll = app.scrollViews["caption-scroll"]
        scroll.swipeDown()
        XCTAssertTrue(app.buttons["follow-latest"].waitForExistence(timeout: 5))
        app.buttons["follow-latest"].tap()
        app.buttons["stop-recording"].tap(); app.alerts.buttons["继续录课"].tap()
        XCTAssertTrue(pause.exists)
        app.buttons["stop-recording"].tap(); app.alerts.buttons["结束并保存"].tap()
        let play = app.buttons["play-lecture"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        waitEnabled(play); play.tap()
        XCTAssertTrue(play.label.contains("播放"))
        play.tap(); capture(app, "detail")
        app.buttons["标记"].tap()
        XCTAssertTrue(app.staticTexts["Review price ceiling"].waitForExistence(timeout: 5))
        app.buttons["摘要"].tap()
        XCTAssertTrue(app.buttons["summary-source-cost"].waitForExistence(timeout: 5))
        capture(app, "summary")
        app.buttons["summary-source-cost"].tap()
        XCTAssertTrue(app.staticTexts["caption-english-20000000-0000-0000-0000-000000000002"].waitForExistence(timeout: 5))
        for _ in 0..<3 where !app.buttons["思维导图"].isHittable { app.swipeDown() }
        app.buttons["思维导图"].tap()
        XCTAssertTrue(app.buttons["map-source-cost"].waitForExistence(timeout: 5))
        capture(app, "mind-map")
        app.buttons["map-source-cost"].tap()
        XCTAssertTrue(app.staticTexts["caption-english-20000000-0000-0000-0000-000000000002"].waitForExistence(timeout: 5))
        app.buttons["导出课堂"].tap()
        enableSwitch("整节录音 · M4A", app: app); enableSwitch("诊断文件", app: app)
        app.buttons["生成导出文件"].tap()
        waitPreparedFiles(app)
        capture(app, "export")
        XCTAssertTrue(app.buttons["分享 / 保存到文件"].isEnabled)
        let language = app.buttons["export-language"]
        if language.exists { language.tap() } else { app.buttons["语言, 双语"].firstMatch.tap() }
        app.buttons["英文"].firstMatch.tap()
        XCTAssertFalse(app.buttons["分享 / 保存到文件"].exists, "A changed option must not share the previous export")
        app.buttons["生成导出文件"].tap()
        waitPreparedFiles(app)
        app.buttons["完成"].firstMatch.tap(); app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.scrollViews["classroom-history"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.scrollViews["caption-scroll"].exists, "Stopped captions must not remain on the home page")
        app.buttons["start-recording"].tap()
        XCTAssertTrue(app.buttons["pause-recording"].waitForExistence(timeout: 10))
    }
    func testCourseSelectionLibraryAndSettings() {
        let app = launch(active: false)
        let start = app.buttons["start-recording"]; XCTAssertTrue(start.waitForExistence(timeout: 20)); waitEnabled(start)
        capture(app, "empty")
        app.buttons["course-picker"].tap()
        let course = app.textFields["new-course-name"]; XCTAssertTrue(course.waitForExistence(timeout: 5))
        course.tap(); course.typeText("FINN1000"); app.buttons["添加并选择"].tap()
        XCTAssertTrue(app.buttons["course-picker"].label.contains("FINN1000"))
        selectTab("首页", app: app)
        XCTAssertTrue(app.staticTexts["ECON1111 · 微观经济学"].waitForExistence(timeout: 5)); capture(app, "history")
        selectTab("设置", app: app)
        XCTAssertTrue(app.staticTexts["本机中文"].waitForExistence(timeout: 5)); capture(app, "settings")
        app.swipeUp(); XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 5)); capture(app, "settings-key")
        app.buttons["状态与诊断"].tap(); XCTAssertTrue(app.staticTexts["当前链路"].waitForExistence(timeout: 5))
    }
    func testLongPressNotesBindToPressedSentenceEachTime() {
        let app = launch(active: true)
        XCTAssertTrue(app.buttons["pause-recording"].waitForExistence(timeout: 20))
        let ids = ["20000000-0000-0000-0000-000000000017", "20000000-0000-0000-0000-000000000016"]
        for (index, id) in ids.enumerated() {
            let row = app.staticTexts["caption-english-\(id)"]
            for _ in 0..<5 where !row.isHittable { app.scrollViews["caption-scroll"].swipeDown() }
            XCTAssertTrue(row.isHittable)
            let source = row.label
            row.press(forDuration: 0.8)
            let noteSource = app.staticTexts["note-source"]
            XCTAssertTrue(noteSource.waitForExistence(timeout: 5)); XCTAssertEqual(noteSource.label, source)
            let editor = app.textViews["note-text"]; editor.tap(); editor.typeText("Sentence note \(index)")
            app.buttons["保存笔记"].tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.press(forDuration: 0.8)
            XCTAssertTrue(noteSource.waitForExistence(timeout: 5)); XCTAssertEqual(noteSource.label, source)
            XCTAssertTrue((editor.value as? String ?? "").contains("Sentence note \(index)"))
            app.buttons["取消"].tap()
            let marker = app.images["caption-mark-\(id)"]
            XCTAssertTrue(marker.waitForExistence(timeout: 5))
            row.doubleTap()
            let unmarked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !marker.exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [unmarked], timeout: 5), .completed)
            row.doubleTap()
            XCTAssertTrue(marker.waitForExistence(timeout: 5))
        }
    }
    func testNewCaptionsCanBeReachedByScrollingWithoutArrow() {
        let app = launch(active: true, extra: ["--wl-live-arrival"])
        XCTAssertTrue(app.buttons["pause-recording"].waitForExistence(timeout: 20))
        let scroll = app.scrollViews["caption-scroll"]
        scroll.swipeDown(); scroll.swipeDown()
        XCTAssertTrue(app.buttons["follow-latest"].waitForExistence(timeout: 5))
        app.buttons["fixture-append-caption"].tap()
        let newest = app.staticTexts["caption-english-20000000-0000-0000-0000-000000000019"]
        for _ in 0..<8 where !newest.isHittable { scroll.swipeUp() }
        scroll.swipeUp()
        XCTAssertTrue(newest.isHittable, "New rows must be in the scroll view while following is suspended")
        let following = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !app.buttons["follow-latest"].exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [following], timeout: 5), .completed)
    }
    func testDarkAndAccessibilityTypeWorkspace() {
        for (argument, name) in [("--wl-dark", "workspace-dark"), ("--wl-large-type", "workspace-large-type")] {
            let app = launch(active: true, extra: [argument])
            XCTAssertTrue(app.buttons["pause-recording"].waitForExistence(timeout: 20))
            capture(app, name)
            XCTAssertTrue(app.buttons["stop-recording"].isHittable)
            app.terminate()
        }
        let app = launch(active: true)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["pause-recording"].waitForExistence(timeout: 20))
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 10), .completed)
        waitForLatestCaption(app)
        waitEnabled(app.buttons["pause-recording"])
        app.buttons["pause-recording"].tap()
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 5))
        app.buttons["pause-recording"].tap()
        XCTAssertTrue(app.staticTexts["录音中"].waitForExistence(timeout: 5))
        waitForLatestCaption(app)
        assertTabletCaptionWidth(app)
        capture(app, "workspace-landscape")
        XCTAssertTrue(app.buttons["stop-recording"].isHittable)
        // A historical reader must not be re-anchored by the same resize task.
        // ScrollView's accessibility frame includes both fixed shelves. A default
        // landscape swipe begins on the controls, so drag inside the reading area.
        let top = app.navigationBars.firstMatch.frame.maxY + 24
        let bottom = app.staticTexts["recording-time"].frame.minY - 24
        XCTAssertGreaterThan(bottom - top, 20)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: top))
        let end = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: bottom))
        for _ in 0..<3 { start.press(forDuration: 0.1, thenDragTo: end) }
        XCTAssertTrue(app.buttons["follow-latest"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.height > app.frame.width }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["follow-latest"].exists, "Rotation must preserve a suspended reader")
        app.buttons["follow-latest"].tap()
        waitForLatestCaption(app)
        assertTabletCaptionWidth(app)
        capture(app, "workspace-portrait-return")
    }
    private func launch(active: Bool, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--wl-ui-fixture"] + (active ? ["--wl-fixture-active"] : []) + extra
        app.launch()
        let control = app.buttons[active ? "pause-recording" : "start-recording"]
        XCTAssertTrue(control.waitForExistence(timeout: 20)); waitEnabled(control)
        if active { waitForLatestCaption(app) }
        return app
    }
    private func waitEnabled(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in element.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed)
    }
    private func waitForLatestCaption(_ app: XCUIApplication) {
        let suffix = "20000000-0000-0000-0000-000000000018"
        let english = app.staticTexts["caption-english-\(suffix)"]
        let chinese = app.staticTexts["caption-chinese-\(suffix)"]
        let timestamp = app.staticTexts["caption-time-\(suffix)"]
        let timer = app.staticTexts["recording-time"]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            english.isHittable && chinese.isHittable && timestamp.isHittable
                && english.frame.minY > 0 && timestamp.frame.maxY < timer.frame.minY
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed, "Following must show the complete latest bilingual row above fixed controls")
    }
    private func assertTabletCaptionWidth(_ app: XCUIApplication) {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let row = app.descendants(matching: .any).matching(identifier: "caption-20000000-0000-0000-0000-000000000018").firstMatch
        XCTAssertTrue(row.exists)
        XCTAssertLessThanOrEqual(row.frame.minX - app.frame.minX, 32, "Tablet subtitles must reach the left reading margin")
        XCTAssertLessThanOrEqual(app.frame.maxX - row.frame.maxX, 32, "Tablet subtitles must reach the right reading margin")
    }
    private func waitPreparedFiles(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["分享 / 保存到文件"].waitForExistence(timeout: 40))
        let count = app.staticTexts["已准备 4 个文件"]
        // iPad's compact native sheet virtualizes the counter below the share row.
        if !count.exists { app.swipeUp() }
        XCTAssertTrue(count.waitForExistence(timeout: 5))
    }
    private func selectTab(_ name: String, app: XCUIApplication) {
        let tab = app.tabBars.buttons[name]
        if tab.exists { tab.tap() } else { app.buttons[name].firstMatch.tap() }
    }
    private func enableSwitch(_ name: String, app: XCUIApplication) {
        let row = app.switches[name].firstMatch
        let control = row.switches.firstMatch
        if control.exists { control.tap() } else { row.tap() }
        XCTAssertEqual(row.value as? String, "1", "Export option must actually be enabled")
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        // Capture the device screen: app.screenshot() can crop a rotated iOS 26 window.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone")-\(name)"
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
