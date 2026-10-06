import XCTest
import UIKit

@MainActor final class V1FlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
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
        app.switches["整节录音 · M4A"].tap(); app.switches["诊断文件"].tap()
        app.buttons["生成导出文件"].tap()
        XCTAssertTrue(app.staticTexts["已准备 4 个文件"].waitForExistence(timeout: 40))
        capture(app, "export")
        XCTAssertTrue(app.buttons["分享 / 保存到文件"].isEnabled)
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
        XCTAssertTrue(app.staticTexts["FINN1000"].exists)
        app.tabBars.buttons["记录"].tap()
        XCTAssertTrue(app.staticTexts["ECON1111 · 微观经济学"].waitForExistence(timeout: 5)); capture(app, "history")
        app.tabBars.buttons["设置"].tap()
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
    }
    private func launch(active: Bool, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--wl-ui-fixture"] + (active ? ["--wl-fixture-active"] : []) + extra
        app.launch(); return app
    }
    private func waitEnabled(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in element.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone")-\(name)"
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
