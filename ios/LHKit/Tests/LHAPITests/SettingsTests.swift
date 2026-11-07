import Foundation
import Testing
@testable import LHAPI

@Suite struct SettingsComposeTests {
	@Test func toolTogglesKeepTheRestOfTheSection() {
		let agent: [String: JSONValue] = ["tools": .object(["demo": .bool(false)]), "unknown": .string("kept")]
		let next = AgentCompose.tool(agent, "research", on: false)
		#expect(next["tools"]?["research"]?.boolValue == false)
		#expect(next["tools"]?["demo"]?.boolValue == false)
		#expect(next["unknown"]?.stringValue == "kept")
	}

	@Test func quizMechanicsWritesExplain() {
		#expect(AgentCompose.quizMechanics([:], freeRecall: true)["tools"]?["explain"]?.boolValue == true)
		#expect(AgentCompose.quizMechanics([:], freeRecall: false)["tools"]?["explain"]?.boolValue == false)
	}

	@Test func fileAccessFolders() {
		var agent = AgentCompose.fileRestriction([:], restricted: true)
		#expect(AgentCompose.restricted(agent))
		agent = AgentCompose.addFolder(agent, "  ~/notes ")
		agent = AgentCompose.addFolder(agent, "~/notes")
		agent = AgentCompose.addFolder(agent, "relative/path")
		#expect(AgentCompose.folders(agent) == ["~/notes"])
		agent = AgentCompose.removeFolder(agent, "~/notes")
		#expect(AgentCompose.folders(agent).isEmpty)
		#expect(AgentCompose.restricted(agent))
	}

	@Test func folderEntries() {
		#expect(isFileAccessFolder("/data/uploads"))
		#expect(isFileAccessFolder("~"))
		#expect(isFileAccessFolder("C:\\Users"))
		#expect(isFileAccessFolder("\\\\server\\share"))
		#expect(!isFileAccessFolder("notes"))
		#expect(!isFileAccessFolder("~notes"))
	}

	@Test func searchEnginePinAndUnpin() {
		let pinned = AgentCompose.searchEngine(["tools": .object([:])], "brave")
		#expect(pinned["search"]?["engine"]?.stringValue == "brave")
		#expect(AgentCompose.searchEngine(pinned, nil)["search"] == nil)
	}

	@Test func promptSwitchRemovesTheKeyWhenOff() {
		let on = AgentCompose.promptSwitch([:], path: "teacher/role.md", on: true)
		#expect(on["prompts"]?["teacher/role.md"]?.boolValue == true)
		#expect(AgentCompose.promptSwitch(on, path: "teacher/role.md", on: false)["prompts"]?.objectValue?.isEmpty == true)
	}

	@Test func slotModelPickKeepsRetention() {
		let models: [String: JSONValue] = ["cheap": .object(["cacheRetention": .string("long"), "thinkingLevel": .string("low")])]
		let next = ModelsCompose.slot(models, .cheap, provider: "openai", id: "gpt-x", thinking: "medium")
		#expect(next["cheap"]?["model"]?["id"]?.stringValue == "gpt-x")
		#expect(next["cheap"]?["thinkingLevel"]?.stringValue == "medium")
		#expect(next["cheap"]?["cacheRetention"]?.stringValue == "long")
	}

	@Test func slotThinkingPickKeepsModel() {
		let models: [String: JSONValue] = ["strong": .object(["model": .object(["provider": .string("a"), "id": .string("b")])])]
		let next = ModelsCompose.slot(models, .strong, provider: "", id: "", thinking: "high")
		#expect(next["strong"]?["model"]?["id"]?.stringValue == "b")
		#expect(next["strong"]?["thinkingLevel"]?.stringValue == "high")
		#expect(ModelsCompose.slot(models, .strong, provider: "", id: "", thinking: "")["strong"] == nil)
	}

	@Test func cacheRetentionDefaultRemovesTheField() {
		let models = ModelsCompose.cacheRetention([:], .vision, "short")
		#expect(models["vision"]?["cacheRetention"]?.stringValue == "short")
		#expect(ModelsCompose.cacheRetention(models, .vision, nil)["vision"]?["cacheRetention"] == nil)
	}

	@Test func tokenInput() {
		#expect(TokenInput.parse("", floor: 500) == .unset)
		#expect(TokenInput.parse("100", floor: 500) == .value(500))
		#expect(TokenInput.parse("8192.4", floor: 500) == .value(8192))
		#expect(TokenInput.parse("-3", floor: 500) == .invalid)
		#expect(TokenInput.parse("abc", floor: 500) == .invalid)
	}

	@Test func settingsReplyFirstBoot() throws {
		let reply = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"settings":null}"#.utf8))
		let snapshot = SettingsSnapshot(reply: reply)
		#expect(snapshot.record.raw["version"]?.intValue == 1)
		#expect(snapshot.fileAccessError == nil)
	}
}

@Suite struct KeyTableTests {
	let providers = [
		ProviderKeyInfo(id: "anthropic", envVar: "ANTHROPIC_API_KEY", label: "Anthropic"),
		ProviderKeyInfo(id: "openai", envVar: "OPENAI_API_KEY", label: "OpenAI"),
		ProviderKeyInfo(id: "opencode", envVar: "OPENCODE_API_KEY", label: "OpenCode Zen"),
		ProviderKeyInfo(id: "opencode-go", envVar: "OPENCODE_API_KEY", label: "OpenCode Go"),
	]

	@Test func classify() {
		let statuses = [
			AuthKeyStatus(id: "ANTHROPIC_API_KEY", present: true, masked: "…ab12 (64 chars)", source: "file"),
			AuthKeyStatus(id: "BRAVE_API_KEY", info: AuthKeyInfo(label: "Brave Search", docsUrl: nil), present: true, masked: "…zz (30 chars)", source: "env"),
			AuthKeyStatus(id: "CUSTOM_OPENAI_API_KEY", present: true, masked: "[redacted]", source: "file"),
			AuthKeyStatus(id: "MYSTERY_VAR", present: true, masked: "…1234 (9 chars)", source: "file"),
		]
		let groups = KeyTable.classify(statuses, providers: providers)
		#expect(groups.providerRows.map(\.id) == ["ANTHROPIC_API_KEY"])
		#expect(groups.toolRows.map(\.id) == KeyTable.toolIDs)
		#expect(groups.toolRows.first { $0.id == "BRAVE_API_KEY" }?.present == true)
		#expect(groups.unknownRows.map(\.id) == ["MYSTERY_VAR"])
		#expect(groups.addable.map(\.id) == ["openai", "opencode", "opencode-go"])
	}

	@Test func statusLine() {
		#expect(KeyTable.statusLine(AuthKeyStatus(id: "X", present: true, masked: "…ab12 (64 chars)", source: "file")) == "…ab12 · 64")
		#expect(KeyTable.statusLine(AuthKeyStatus(id: "X", present: true, masked: "…ab12 (64 chars)", source: "env")) == "…ab12 · 64 · env")
		#expect(KeyTable.statusLine(AuthKeyStatus(id: "X")) == "not set")
	}

	@Test func sharedCredentialLabel() {
		#expect(KeyTable.providerLabel("OPENCODE_API_KEY", providers: providers) == "OpenCode (Zen / Go)")
		#expect(KeyTable.providerLabel("OPENAI_API_KEY", providers: providers) == "OpenAI")
	}
}

@Suite struct PromptViewTests {
	@Test func sharedChunksListedOnceWithUsage() {
		func seg(_ path: String, shared: Bool) -> PromptSegment {
			PromptSegment(path: path, sourceText: "", overrideText: nil, enabled: false, shared: shared)
		}
		let view = PromptView(
			teacher: [seg("teacher/role.md", shared: false), seg("shared/style.md", shared: true)],
			prober: [seg("shared/style.md", shared: true), seg("prober/role.md", shared: false)],
			practice: [seg("practice/role.md", shared: false)]
		)
		let sections = view.sections
		#expect(sections.map(\.label) == ["Teacher", "Prober", "Practice", "Shared"])
		#expect(sections[0].rows.map(\.id) == ["teacher/role.md"])
		#expect(sections[3].rows.map(\.id) == ["shared/style.md"])
		#expect(sections[3].rows[0].usageHint == "Used by Teacher and Prober")
	}

	@Test func promptPathKeepsSlashes() {
		#expect(APIClient.promptPath("shared/a b.md") == "shared/a%20b.md")
	}
}

@Suite struct ConnectionsTests {
	@Test func pinPayloadDropsBlankModels() {
		var drafts = CustomPinDraft.drafts([CustomModel(id: "a"), CustomModel(id: "b")], ["a": CustomModelOverride(context: 32000)])
		#expect(drafts["a"]?.context == "32000")
		drafts["b"]?.reasoning = "off"
		drafts["a"]?.context = " "
		let payload = CustomPinDraft.payload(drafts)
		#expect(payload["a"] == nil)
		#expect(payload["b"] == CustomModelOverride(reasoning: false))
	}

	@Test func customStatusSummary() throws {
		let reply = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"baseUrl":"http://h/v1","authMode":"apiKey","keyPresent":false,"models":[{"id":"m"}]}"#.utf8))
		let status = CustomProviderStatus(reply: reply, revision: "\"r\"")
		#expect(status.summary == "http://h/v1 · 1 model · API key missing")
		#expect(status.isConfigured)
	}

	@Test func subscriptionStatusDecodes() throws {
		let json = #"[{"providerId":"github-copilot","available":true,"connected":false,"pending":true,"allowBackgroundUse":true,"connectionId":null,"epoch":0,"authorityRevision":0,"revision":3,"interaction":{"attemptId":"a1","userCode":"ABCD-1234","browser":{"id":"b1","url":"https://github.com/login/device"}}}]"#
		let statuses = try JSONDecoder().decode([SubscriptionStatus].self, from: Data(json.utf8))
		#expect(statuses[0].interaction?.userCode == "ABCD-1234")
		#expect(statuses[0].interaction?.browser?.id == "b1")
	}

	@Test func visionChoicesPutImageModelsFirst() throws {
		let json = #"{"models":[{"id":"t","name":"T","provider":"p","reasoning":false,"supportedLevels":[],"input":["text"]},{"id":"c","name":"C","provider":"custom","reasoning":false,"supportedLevels":[],"input":["text"]},{"id":"v","name":"V","provider":"p","reasoning":false,"supportedLevels":[],"input":["text","image"],"cost":{"input":0.5,"output":2}}],"defaults":null,"slots":{"strong":null,"cheap":{"model":{"provider":"p","id":"t"}},"vision":null}}"#
		let catalog = try JSONDecoder().decode(ModelCatalog.self, from: Data(json.utf8))
		#expect(catalog.choices(for: .vision).map(\.id) == ["v", "c"])
		#expect(catalog.choices(for: .strong).count == 3)
		#expect(catalog.slotPin(.cheap)?.model.id == "t")
		#expect(catalog.slotPin(.strong) == nil)
		#expect(catalog.models[2].priceLabel == "$0.5/$2.00")
		#expect(catalog.models[0].priceLabel == "Unpriced")
	}
}
