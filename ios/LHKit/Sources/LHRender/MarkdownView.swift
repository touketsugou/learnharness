import Markdown
import SwiftUI

/// Renders the server's display-normalized Markdown natively: CommonMark +
/// GFM (swift-markdown), single newlines as line breaks (the web's
/// remark-breaks), inline and display LaTeX via SwiftMath, ```mermaid fences
/// as diagram cards. Raw HTML is shown as text, never executed.
public struct MarkdownView: View {
	private let source: String
	private let textStyle: Font.TextStyle

	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.openURL) private var openURL

	public init(_ source: String, textStyle: Font.TextStyle = .body) {
		self.source = source
		self.textStyle = textStyle
	}

	public var body: some View {
		let parsed = ParsedMarkdown.cached(source)
		VStack(alignment: .leading, spacing: 10) {
			ForEach(Array(parsed.chunks.enumerated()), id: \.offset) { _, chunk in
				switch chunk {
				case .display(let latex):
					DisplayMathView(latex: latex, textStyle: textStyle)
				case .markdown(let document, let math):
					BlockList(blocks: Array(document.children), context: context(math))
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func context(_ math: [String]) -> RenderContext {
		RenderContext(math: math, textStyle: textStyle, dark: colorScheme == .dark)
	}
}

/// One top-level block (a paragraph, list, code block, display math…) of the
/// same Markdown MarkdownView renders, so a lazy list can lay out a long text
/// as rows of bounded height. Blocks stacked 10 apart look like MarkdownView.
public struct MarkdownBlock: View {
	private let source: String
	private let index: Int
	private let textStyle: Font.TextStyle

	@Environment(\.colorScheme) private var colorScheme

	public init(_ source: String, index: Int, textStyle: Font.TextStyle = .body) {
		self.source = source
		self.index = index
		self.textStyle = textStyle
	}

	/// The number of top-level blocks in `source`; whitespace alone has none.
	public static func count(_ source: String) -> Int { ParsedMarkdown.cached(source).blocks.count }

	public var body: some View {
		let blocks = ParsedMarkdown.cached(source).blocks
		Group {
			if index < blocks.count {
				switch blocks[index] {
				case .display(let latex):
					DisplayMathView(latex: latex, textStyle: textStyle)
				case .markdown(let block, let math):
					BlockView(block: block, context: RenderContext(math: math, textStyle: textStyle, dark: colorScheme == .dark))
				}
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

// MARK: - Parsing cache

final class ParsedMarkdown: @unchecked Sendable {
	enum Chunk {
		case markdown(Markdown.Document, [String])
		case display(String)
	}

	enum Block {
		case markdown(any Markup, [String])
		case display(String)
	}

	let chunks: [Chunk]
	/// The chunks' top-level blocks in order, for MarkdownBlock.
	let blocks: [Block]

	init(_ source: String) {
		chunks = MathSegmenter.segment(source).map { chunk in
			switch chunk {
			case .markdown(let text, let math): .markdown(Markdown.Document(parsing: text), math)
			case .displayMath(let latex): .display(latex)
			}
		}
		blocks = chunks.flatMap { chunk -> [Block] in
			switch chunk {
			case .markdown(let document, let math): document.children.map { .markdown($0, math) }
			case .display(let latex): [.display(latex)]
			}
		}
	}

	nonisolated(unsafe) private static let cache: NSCache<NSString, ParsedMarkdown> = {
		let cache = NSCache<NSString, ParsedMarkdown>()
		cache.countLimit = 400
		return cache
	}()

	static func cached(_ source: String) -> ParsedMarkdown {
		if let hit = cache.object(forKey: source as NSString) { return hit }
		let parsed = ParsedMarkdown(source)
		cache.setObject(parsed, forKey: source as NSString)
		return parsed
	}
}

// MARK: - Blocks

struct RenderContext {
	let math: [String]
	let textStyle: Font.TextStyle
	let dark: Bool

	var fontSize: CGFloat { UIFont.preferredFont(forTextStyle: textStyle.uiTextStyle).pointSize }
}

private struct BlockList: View {
	let blocks: [any Markup]
	let context: RenderContext

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
				BlockView(block: block, context: context)
			}
		}
	}
}

private struct BlockView: View {
	let block: any Markup
	let context: RenderContext

	var body: some View {
		content
	}

	@ViewBuilder private var content: some View {
		switch block {
		case let paragraph as Paragraph:
			InlineText(container: paragraph, context: context)
		case let heading as Heading:
			InlineText(container: heading, context: context, font: headingFont(heading.level))
				.padding(.top, heading.level <= 2 ? 6 : 2)
		case let quote as BlockQuote:
			HStack(alignment: .top, spacing: 10) {
				RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3)
				BlockList(blocks: Array(quote.children), context: context)
					.foregroundStyle(.secondary)
			}
		case let list as UnorderedList:
			ListBlock(items: Array(list.listItems), ordered: nil, context: context)
		case let list as OrderedList:
			ListBlock(items: Array(list.listItems), ordered: Int(list.startIndex), context: context)
		case let code as CodeBlock:
			if code.language?.lowercased() == "mermaid" {
				MermaidView(source: code.code)
			} else {
				CodeBlockView(code: code.code)
			}
		case let table as Markdown.Table:
			TableBlock(table: table, context: context)
		case is ThematicBreak:
			Divider().padding(.vertical, 4)
		case let html as HTMLBlock:
			CodeBlockView(code: html.rawHTML)
		default:
			SwiftUI.Text(verbatim: block.format())
		}
	}

	private func headingFont(_ level: Int) -> Font {
		switch level {
		case 1: .title2.weight(.semibold)
		case 2: .title3.weight(.semibold)
		default: .headline
		}
	}
}

private struct ListBlock: View {
	let items: [ListItem]
	/// Start number for ordered lists; nil for bullets.
	let ordered: Int?
	let context: RenderContext

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
				HStack(alignment: .firstTextBaseline, spacing: 8) {
					marker(offset, item)
						.font(Font.system(context.textStyle).monospacedDigit())
						.foregroundStyle(.secondary)
					BlockList(blocks: Array(item.children), context: context)
				}
			}
		}
	}

	@ViewBuilder private func marker(_ offset: Int, _ item: ListItem) -> some View {
		switch item.checkbox {
		case .checked: SwiftUI.Image(systemName: "checkmark.square")
		case .unchecked: SwiftUI.Image(systemName: "square")
		case nil:
			if let start = ordered { SwiftUI.Text(verbatim: "\(start + offset).") } else { SwiftUI.Text(verbatim: "•") }
		}
	}
}

private struct TableBlock: View {
	let table: Markdown.Table
	let context: RenderContext

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
				GridRow {
					ForEach(Array(table.head.cells.enumerated()), id: \.offset) { _, cell in
						InlineText(container: cell, context: context, font: Font.system(context.textStyle).weight(.semibold))
					}
				}
				Divider()
				ForEach(Array(table.body.rows.enumerated()), id: \.offset) { _, row in
					GridRow {
						ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
							InlineText(container: cell, context: context)
						}
					}
				}
			}
			.padding(.vertical, 4)
		}
	}
}

struct CodeBlockView: View {
	let code: String

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			SwiftUI.Text(verbatim: code.hasSuffix("\n") ? String(code.dropLast()) : code)
				.font(.system(.callout, design: .monospaced))
				.textSelection(.enabled)
				.padding(12)
		}
		.background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .secondarySystemBackground)))
	}
}

// MARK: - Inline

private struct InlineText: View {
	let container: any Markup
	let context: RenderContext
	var font: Font?

	var body: some View {
		InlineBuilder(context: context).text(for: container)
			.font(font ?? Font.system(context.textStyle))
			.fixedSize(horizontal: false, vertical: true)
			.textSelection(.enabled)
	}
}

@MainActor
private struct InlineBuilder {
	let context: RenderContext

	func text(for container: any Markup) -> SwiftUI.Text {
		join(container.children.map { inline($0) })
	}

	private func join(_ parts: [SwiftUI.Text]) -> SwiftUI.Text {
		parts.reduce(SwiftUI.Text(verbatim: "")) { SwiftUI.Text("\($0)\($1)") }
	}

	private func inline(_ markup: any Markup) -> SwiftUI.Text {
		switch markup {
		case let text as Markdown.Text:
			return join(MathSegmenter.runs(in: text.string).map { run in
				if let index = run.math { return math(index) }
				return SwiftUI.Text(verbatim: run.text)
			})
		case let strong as Strong:
			return text(for: strong).bold()
		case let emphasis as Emphasis:
			return text(for: emphasis).italic()
		case let strike as Strikethrough:
			return text(for: strike).strikethrough()
		case let code as InlineCode:
			return SwiftUI.Text(verbatim: code.code).font(.system(context.textStyle, design: .monospaced))
		case let link as Markdown.Link:
			var label = AttributedString(link.plainText)
			if let destination = link.destination, let url = URL(string: destination) {
				label.link = url
				label.underlineStyle = .single
			}
			return SwiftUI.Text(label)
		case let image as Markdown.Image:
			return SwiftUI.Text(verbatim: image.plainText.isEmpty ? "[image]" : image.plainText).italic()
		case is SoftBreak, is LineBreak:
			return SwiftUI.Text(verbatim: "\n")
		case let html as InlineHTML:
			return SwiftUI.Text(verbatim: html.rawHTML)
		default:
			return SwiftUI.Text(verbatim: markup.format())
		}
	}

	private func math(_ index: Int) -> SwiftUI.Text {
		guard context.math.indices.contains(index) else { return SwiftUI.Text(verbatim: "") }
		let latex = context.math[index]
		guard let rendered = MathRenderer.shared.render(latex, fontSize: context.fontSize, dark: context.dark, display: false) else {
			return SwiftUI.Text(verbatim: "$\(latex)$").font(.system(context.textStyle, design: .monospaced))
		}
		return SwiftUI.Text(SwiftUI.Image(uiImage: rendered.image)).baselineOffset(-rendered.descent)
	}
}

// MARK: - Display math

struct DisplayMathView: View {
	let latex: String
	let textStyle: Font.TextStyle
	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		let size = UIFont.preferredFont(forTextStyle: textStyle.uiTextStyle).pointSize * 1.1
		if let rendered = MathRenderer.shared.render(latex, fontSize: size, dark: colorScheme == .dark, display: true) {
			ScrollView(.horizontal, showsIndicators: false) {
				SwiftUI.Image(uiImage: rendered.image)
					.accessibilityLabel(SwiftUI.Text(verbatim: latex))
					.padding(.vertical, 4)
			}
			.frame(maxWidth: .infinity)
		} else {
			CodeBlockView(code: latex)
		}
	}
}

extension Font.TextStyle {
	var uiTextStyle: UIFont.TextStyle {
		switch self {
		case .largeTitle: .largeTitle
		case .title: .title1
		case .title2: .title2
		case .title3: .title3
		case .headline: .headline
		case .subheadline: .subheadline
		case .callout: .callout
		case .footnote: .footnote
		case .caption: .caption1
		case .caption2: .caption2
		default: .body
		}
	}
}
