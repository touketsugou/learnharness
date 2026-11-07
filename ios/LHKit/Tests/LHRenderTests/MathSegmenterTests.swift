import Testing
@testable import LHRender

@Suite("Math segmentation")
struct MathSegmenterTests {
	typealias Chunk = MathSegmenter.Chunk
	let p = MathSegmenter.placeholder

	@Test func liftsInlineMathOfBothWidths() {
		#expect(MathSegmenter.segment("Area $\\pi r^2$ and $$x_1$$ done.") == [
			.markdown("Area \(p(0)) and \(p(1)) done.", inlineMath: ["\\pi r^2", "x_1"]),
		])
	}

	@Test func fencesDisplayMathOnItsOwnLines() {
		let source = "Before\n\n$$\n\\int_0^1 x\\,dx\n$$\n\nAfter $y$"
		#expect(MathSegmenter.segment(source) == [
			.markdown("Before\n", inlineMath: []),
			.displayMath("\\int_0^1 x\\,dx"),
			.markdown("\nAfter \(p(0))", inlineMath: ["y"]),
		])
	}

	@Test func unclosedDisplayMathRunsToTheEnd() {
		#expect(MathSegmenter.segment("Hi\n$$\na+b") == [.markdown("Hi", inlineMath: []), .displayMath("a+b")])
	}

	@Test func leavesCodeEscapesAndBareDollarsAlone() {
		let source = "Cost \\$5 and `$x$` here\n```\n$$\n$a$\n```\nlone $ sign"
		#expect(MathSegmenter.segment(source) == [.markdown(source, inlineMath: [])])
	}

	@Test func mathNeverCrossesABlankLine() {
		#expect(MathSegmenter.segment("$a\n\nb$") == [.markdown("$a\n\nb$", inlineMath: [])])
		#expect(MathSegmenter.segment("$a\nb$") == [.markdown(p(0), inlineMath: ["a\nb"])])
	}

	@Test func splitsTextRunsAroundPlaceholders() {
		let runs = MathSegmenter.runs(in: "x \(p(0)) y\(p(12))")
		#expect(runs.map(\.text) == ["x ", "", " y", ""])
		#expect(runs.map(\.math) == [nil, 0, nil, 12])
		#expect(MathSegmenter.runs(in: "broken \u{E000}12").map(\.text) == ["broken \u{E000}12"])
	}
}
