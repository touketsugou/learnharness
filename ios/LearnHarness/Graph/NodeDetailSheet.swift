import LHAPI
import SwiftUI

/// A node's detail (web detail card): name, statement, the reasoning chains
/// it takes part in, the sessions and notes it came from, and Delete.
struct NodeDetailSheet: View {
	let node: GraphProposition
	let snapshot: GraphSnapshot
	let model: GraphModel
	let onSelectNode: (String) -> Void
	let onOpenSession: (String, String?) -> Void
	let onDeleted: () -> Void

	@State private var confirmDelete = false
	@State private var deleting = false
	@State private var error: String?

	var body: some View {
		NavigationStack {
			List {
				Section {
					Text(node.statement).textSelection(.enabled)
				}
				if !supportedBy.isEmpty {
					Section("Supported by") {
						ForEach(supportedBy) { chain in ChainLine(chain: chain, snapshot: snapshot, current: node.id, onSelect: onSelectNode) }
					}
				}
				if !leadsTo.isEmpty {
					Section("Leads to") {
						ForEach(leadsTo) { chain in ChainLine(chain: chain, snapshot: snapshot, current: node.id, onSelect: onSelectNode) }
					}
				}
				Section("Sessions") {
					if sources.isEmpty {
						Text("No sessions recorded.").foregroundStyle(.secondary)
					}
					ForEach(sources, id: \.self) { source in sourceRow(source) }
				}
				Section {
					Button("Delete node", systemImage: "trash", role: .destructive) { confirmDelete = true }
						.disabled(deleting || model.offline)
				} footer: {
					if let error { Text(error).foregroundStyle(.red) }
				}
			}
			.navigationTitle(node.name)
			.navigationBarTitleDisplayMode(.inline)
			.alert("Delete node?", isPresented: $confirmDelete) {
				Button("Cancel", role: .cancel) {}
				Button("Delete", role: .destructive) { Task { await delete() } }
			} message: {
				Text("\(node.name)\n\nThis permanently deletes the node — this cannot be undone.")
			}
		}
	}

	private var supportedBy: [GraphChain] { snapshot.chains.filter { $0.conclusion == node.id } }
	private var leadsTo: [GraphChain] { snapshot.chains.filter { $0.premises.contains(node.id) } }

	/// The sources that touched the node, first appearance first.
	private var sources: [String] {
		var seen = Set<String>()
		return node.provenance.map(\.chatId).filter { seen.insert($0).inserted }
	}

	@ViewBuilder private func sourceRow(_ source: String) -> some View {
		if let path = snapshot.fileSources[source] {
			// Imported notes: a static entry, never a link.
			Label(path, systemImage: "doc.text").foregroundStyle(.secondary).lineLimit(2)
		} else {
			Button {
				let message = node.provenance.first { $0.chatId == source && !$0.messageId.isEmpty }?.messageId
				onOpenSession(source, message)
			} label: {
				Label(snapshot.sessions[source] ?? source, systemImage: "text.bubble")
			}
		}
	}

	private func delete() async {
		deleting = true
		error = nil
		do {
			try await model.deleteNode(node.id)
			onDeleted()
		} catch {
			self.error = (error as? APIError)?.message ?? error.localizedDescription
		}
		deleting = false
	}
}

/// One chain as the web chain line: premise chips joined by ∧, then ⟹ and
/// the conclusion. Tapping another node's chip selects it.
struct ChainLine: View {
	let chain: GraphChain
	let snapshot: GraphSnapshot
	let current: String?
	let onSelect: (String) -> Void

	var body: some View {
		FlowLayout(spacing: 6) {
			ForEach(Array(chain.premises.enumerated()), id: \.offset) { index, premise in
				if index > 0 { Text("∧").foregroundStyle(.secondary) }
				chip(premise)
			}
			Text("⟹").foregroundStyle(.secondary)
			chip(chain.conclusion)
		}
		.padding(.vertical, 2)
	}

	private func chip(_ id: String) -> some View {
		let name = snapshot.propositions.first { $0.id == id }?.name ?? "Deleted node"
		return Button { onSelect(id) } label: {
			Text(name)
				.font(.callout.weight(id == current ? .semibold : .regular))
				.padding(.horizontal, 8)
				.padding(.vertical, 3)
				.overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
		}
		.buttonStyle(.plain)
		.disabled(id == current)
	}
}

/// Left-to-right wrapping layout for chips.
struct FlowLayout: Layout {
	var spacing: CGFloat = 6

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let width = proposal.width ?? .greatestFiniteMagnitude
		var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
		for subview in subviews {
			let size = subview.sizeThatFits(.unspecified)
			if x > 0, x + size.width > width {
				y += line + spacing
				x = 0
				line = 0
			}
			x += size.width + spacing
			line = max(line, size.height)
			widest = max(widest, x - spacing)
		}
		// Report the full proposed width: placement then wraps at the same
		// width the height was measured at.
		return CGSize(width: proposal.width ?? widest, height: y + line)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
		for subview in subviews {
			let size = subview.sizeThatFits(.unspecified)
			if x > bounds.minX, x + size.width > bounds.maxX {
				y += line + spacing
				x = bounds.minX
				line = 0
			}
			subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
			x += size.width + spacing
			line = max(line, size.height)
		}
	}
}
