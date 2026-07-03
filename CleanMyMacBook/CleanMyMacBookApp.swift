import SwiftUI

@main
struct CleanMyMacBookApp: App {
    @StateObject private var controller = CleaningController()

    var body: some Scene {
        MenuBarExtra("Mac 清洁助手", systemImage: "sparkles") {
            ContentView(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}
