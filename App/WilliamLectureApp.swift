import SwiftUI

@main struct WilliamLectureApp: App {
    @StateObject private var controller = LectureController()
    var body: some Scene { WindowGroup { LectureRootView().environmentObject(controller).modifier(UIFixtureAppearance()) } }
}
