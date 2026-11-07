import SwiftUI

@main
struct LearnHarnessApp: App {
	@State private var model = AppModel()

	var body: some Scene {
		WindowGroup {
			RootView()
				.environment(model)
		}
	}
}
