import SwiftUI

struct RootView: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		if model.client != nil {
			SessionsView()
		} else {
			ConnectionView()
		}
	}
}
