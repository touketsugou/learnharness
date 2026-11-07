// swift-tools-version: 6.2
// LHKit — the iOS client's networking (LHAPI), offline cache (LHCache) and
// content rendering (LHRender). See ios/README.md.
import PackageDescription

let package = Package(
	name: "LHKit",
	platforms: [.iOS("27.0")],
	products: [
		.library(name: "LHAPI", targets: ["LHAPI"]),
		.library(name: "LHCache", targets: ["LHCache"]),
		.library(name: "LHRender", targets: ["LHRender"]),
	],
	dependencies: [
		.package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
		.package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3"),
	],
	targets: [
		.target(name: "LHAPI"),
		.target(name: "LHCache", dependencies: ["LHAPI"]),
		.target(
			name: "LHRender",
			dependencies: [
				"LHAPI",
				.product(name: "Markdown", package: "swift-markdown"),
				.product(name: "SwiftMath", package: "SwiftMath"),
			],
			resources: [.copy("Resources/web")]
		),
		.testTarget(name: "LHAPITests", dependencies: ["LHAPI"]),
		.testTarget(name: "LHCacheTests", dependencies: ["LHCache"]),
		.testTarget(name: "LHRenderTests", dependencies: ["LHRender"]),
	]
)
