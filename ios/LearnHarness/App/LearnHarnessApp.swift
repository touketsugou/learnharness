import SwiftUI

@main
struct LearnHarnessApp: App {
	@State private var model = AppModel()
	@Environment(\.scenePhase) private var scenePhase

	var body: some Scene {
		WindowGroup {
			RootView()
				.environment(model)
		}
		.onChange(of: scenePhase) { _, phase in model.sceneChanged(phase) }
	}
}
