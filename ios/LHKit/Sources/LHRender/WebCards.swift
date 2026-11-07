import SwiftUI
import WebKit

// Web content the native renderer cannot draw itself: Mermaid diagrams, SVG
// visuals, and (later) interactive demos. Every card is an isolated
// non-persistent WKWebView whose network access is blocked by a content rule
// list; link navigation is refused. App scripts (sizing, Mermaid) run in an
// isolated content world, so page scripts can neither see nor spoof them.

/// What a web card loads.
public struct WebCardContent: Equatable, Sendable {
	public var html: String
	/// Scripts injected at document end in the app's isolated content world.
	public var appScripts: [String]
	/// Allow scripts authored by the page itself (interactive demos).
	public var pageScripts: Bool

	public init(html: String, appScripts: [String] = [], pageScripts: Bool = false) {
		self.html = html
		self.appScripts = appScripts
		self.pageScripts = pageScripts
	}
}

/// A web card that sizes itself to its content height.
public struct WebCardView: View {
	let content: WebCardContent
	let maxHeight: CGFloat?
	@State private var height: CGFloat = 80

	public init(content: WebCardContent, maxHeight: CGFloat? = nil) {
		self.content = content
		self.maxHeight = maxHeight
	}

	public var body: some View {
		WebCardRepresentable(content: content, height: $height)
			.frame(height: maxHeight.map { min(height, $0) } ?? height)
	}
}

@MainActor
enum NetworkBlocker {
	private static var compiled: WKContentRuleList?

	/// Blocks every network-scheme load; local HTML strings still render.
	static func ruleList() async -> WKContentRuleList? {
		if let compiled { return compiled }
		let rules = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp|blob):"},"action":{"type":"block"}}]"#
		compiled = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "lh-block-network", encodedContentRuleList: rules)
		return compiled
	}
}

struct WebCardRepresentable: UIViewRepresentable {
	let content: WebCardContent
	@Binding var height: CGFloat

	static let sizeScript = """
	(() => {
		const post = () => window.webkit.messageHandlers.lhSize.postMessage(Math.ceil(document.documentElement.scrollHeight));
		new ResizeObserver(post).observe(document.documentElement);
		window.addEventListener('load', post);
		post();
	})();
	"""

	func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

	func makeUIView(context: Context) -> WKWebView {
		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		configuration.defaultWebpagePreferences.allowsContentJavaScript = content.pageScripts
		configuration.suppressesIncrementalRendering = true
		let controller = configuration.userContentController
		controller.add(WeakMessageHandler(context.coordinator), contentWorld: .defaultClient, name: "lhSize")
		for script in content.appScripts + [Self.sizeScript] {
			controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
		}
		let webView = WKWebView(frame: .zero, configuration: configuration)
		webView.isOpaque = false
		webView.backgroundColor = .clear
		webView.scrollView.backgroundColor = .clear
		webView.scrollView.isScrollEnabled = content.pageScripts
		webView.navigationDelegate = context.coordinator
		context.coordinator.load(content, into: webView)
		return webView
	}

	func updateUIView(_ webView: WKWebView, context: Context) {
		if context.coordinator.loaded != content { context.coordinator.load(content, into: webView) }
	}

	static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
		webView.configuration.userContentController.removeAllScriptMessageHandlers()
	}

	@MainActor
	final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
		var height: Binding<CGFloat>
		var loaded: WebCardContent?

		init(height: Binding<CGFloat>) { self.height = height }

		func load(_ content: WebCardContent, into webView: WKWebView) {
			loaded = content
			Task {
				if let rules = await NetworkBlocker.ruleList() {
					webView.configuration.userContentController.add(rules)
				}
				webView.loadHTMLString(content.html, baseURL: nil)
			}
		}

		func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
			guard let value = message.body as? NSNumber else { return }
			let next = max(20, CGFloat(truncating: value))
			if abs(next - height.wrappedValue) > 0.5 { height.wrappedValue = next }
		}

		func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
			// Only the initial HTML string load; never follow links or redirects.
			action.navigationType == .other && (action.request.url?.absoluteString ?? "about:blank") == "about:blank" ? .allow : .cancel
		}
	}
}

/// Breaks the WKUserContentController → handler retain cycle.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
	weak var target: (any WKScriptMessageHandler)?
	init(_ target: any WKScriptMessageHandler) { self.target = target }
	@MainActor
	func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
		target?.userContentController(controller, didReceive: message)
	}
}

// MARK: - Documents

enum WebDocument {
	static func escape(_ text: String) -> String {
		text.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
			.replacingOccurrences(of: "\"", with: "&quot;")
	}

	/// A transparent page that follows the system appearance. Page-authored
	/// scripts are refused by CSP unless the card allows them.
	static func page(body: String, pageScripts: Bool, extraStyle: String = "") -> String {
		let scriptPolicy = pageScripts ? "'unsafe-inline' 'unsafe-eval'" : "'none'"
		return """
		<!doctype html><html><head><meta charset="utf-8">
		<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
		<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; script-src \(scriptPolicy)">
		<style>
		:root { color-scheme: light dark; }
		html, body { margin: 0; padding: 0; background: transparent; font: -apple-system-body; color: CanvasText; }
		\(extraStyle)
		</style></head><body>\(body)</body></html>
		"""
	}
}

// MARK: - Mermaid

enum MermaidAsset {
	/// mermaid.min.js vendored by ios/scripts/vendor-web.sh (nil when missing).
	static let source: String? = Bundle.module.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "web")
		.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
}

/// A ```mermaid fence rendered with the vendored Mermaid library (strict
/// security level, no page scripts); falls back to the source as code.
public struct MermaidView: View {
	let source: String
	@Environment(\.colorScheme) private var colorScheme

	public init(source: String) { self.source = source }

	public var body: some View {
		if let library = MermaidAsset.source {
			WebCardView(content: content(library: library))
				.padding(.vertical, 4)
		} else {
			CodeBlockView(code: source)
		}
	}

	private func content(library: String) -> WebCardContent {
		let theme = colorScheme == .dark ? "dark" : "default"
		let run = """
		mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: '\(theme)' });
		mermaid.run({ querySelector: '.mermaid' }).catch((error) => {
			const pre = document.createElement('pre');
			pre.textContent = String(error && error.message || error);
			document.body.appendChild(pre);
		});
		"""
		let html = WebDocument.page(
			body: "<pre class=\"mermaid\">\(WebDocument.escape(source))</pre>",
			pageScripts: false,
			extraStyle: ".mermaid { display: flex; justify-content: center; margin: 0; } svg { max-width: 100%; height: auto; }"
		)
		return WebCardContent(html: html, appScripts: [library, run])
	}
}

// MARK: - SVG

/// An SVG visual (the visual-maker's output), scripts refused.
public struct SVGView: View {
	let svg: String

	public init(svg: String) { self.svg = svg }

	public var body: some View {
		WebCardView(content: WebCardContent(html: WebDocument.page(
			body: "<div class=\"svg\">\(svg)</div>",
			pageScripts: false,
			extraStyle: ".svg { display: flex; justify-content: center; } .svg svg { max-width: 100%; height: auto; }"
		)))
	}
}
