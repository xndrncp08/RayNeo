import SwiftUI

@main
struct RayNeoInterviewCompanionApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            DashboardView(model: model)
                .onChange(of: scenePhase) { _, phase in model.handleScenePhase(phase) }
        }
    }
}
