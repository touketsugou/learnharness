import SwiftUI

struct RootView: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		@Bindable var model = model
		if model.client != nil {
			TabView(selection: $model.tab) {
				Tab("Sessions", systemImage: "text.bubble", value: AppTab.sessions) {
					SessionsView()
				}
				Tab("Graph", systemImage: "point.3.connected.trianglepath.dotted", value: AppTab.graph) {
					GraphScreen()
				}
			}
		} else {
			ConnectionView()
		}
	}
}
