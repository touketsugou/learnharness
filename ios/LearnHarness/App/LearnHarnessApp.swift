import LHRender
import SwiftUI

@main
struct LearnHarnessApp: App {
	@State private var model = AppModel()
	@Environment(\.scenePhase) private var scenePhase

	init() {
		LHFonts.register()
	}

	var body: some Scene {
		WindowGroup {
			RootView()
				.environment(model)
				// Dark only: the desktop's palette.
				.preferredColorScheme(.dark)
				.tint(LHColor.ink)
				.background(LHColor.bg.ignoresSafeArea())
		}
		.onChange(of: scenePhase) { _, phase in model.sceneChanged(phase) }
	}
}
