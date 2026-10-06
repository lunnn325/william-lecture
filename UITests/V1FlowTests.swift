import XCTest
import UIKit

@MainActor final class V1FlowTests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    func testReadingMarkNotePauseStopPlaybackAndExport() {
        let app = launch(active: true)
        let pause = app.buttons["pause-recording"]
        XCTAssertTrue(pause.waitForExistence(timeout: 20))
        capture(app, "workspace-light")
        app.buttons["add-note"].tap()
        app.buttons["add-note"].press(forDuration: 1)
        app.buttons["写笔记"].tap()
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
        XCTAssertTrue(app.buttons["start-recording"].waitForExistence(timeout: 10))
        app.buttons["查看这节课"].tap()
        let play = app.buttons["play-lecture"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        waitEnabled(play); play.tap()
        XCTAssertTrue(play.label.contains("暂停"))
        play.tap(); capture(app, "detail")
        XCTAssertTrue(app.staticTexts["Review price ceiling"].exists)
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
        app.buttons["完成"].firstMatch.tap(); app.buttons["完成"].firstMatch.tap()
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
        selectTab("记录", app: app)
        XCTAssertTrue(app.staticTexts["ECON1111 · 微观经济学"].waitForExistence(timeout: 5)); capture(app, "history")
        selectTab("设置", app: app)
        XCTAssertTrue(app.staticTexts["本机中文"].waitForExistence(timeout: 5)); capture(app, "settings")
        app.swipeUp(); XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 5)); capture(app, "settings-key")
        app.buttons["状态与诊断"].tap(); XCTAssertTrue(app.staticTexts["当前链路"].waitForExistence(timeout: 5))
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
        app.buttons["pause-recording"].tap()
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 5))
        app.buttons["pause-recording"].tap()
        XCTAssertTrue(app.staticTexts["录音中"].waitForExistence(timeout: 5))
        waitForLatestCaption(app)
        capture(app, "workspace-landscape")
        XCTAssertTrue(app.buttons["stop-recording"].isHittable)
        // A historical reader must not be re-anchored by the same resize task.
        let scroll = app.scrollViews["caption-scroll"]
        for _ in 0..<3 { scroll.swipeDown() }
        XCTAssertTrue(app.buttons["follow-latest"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.height > app.frame.width }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["follow-latest"].exists, "Rotation must preserve a suspended reader")
        app.buttons["follow-latest"].tap()
        waitForLatestCaption(app)
    }
    private func launch(active: Bool, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--wl-ui-fixture"] + (active ? ["--wl-fixture-active"] : []) + extra
        app.launch(); return app
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
