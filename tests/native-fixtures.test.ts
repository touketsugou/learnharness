/**
 * Native-contract fixtures (iOS client, 2026-11-07): the committed JSON the
 * Swift decoder tests read must equal what the server projects today, and
 * every view/frame must satisfy the contract schema. Regenerate with
 * `npx tsx scripts/export-native-fixtures.ts` after an intentional change.
 */
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { Value } from "typebox/value";
import { generateNativeFixtures, NATIVE_FIXTURES_DIR } from "../scripts/export-native-fixtures.ts";

const fixtures = await generateNativeFixtures();
const { NativeSessionViewSchema, NativeStreamFrameSchema } = await import("../src/core/contracts/native.ts");

test("committed native fixtures match the current projection", () => {
	const committed = fs.readdirSync(NATIVE_FIXTURES_DIR).filter((f) => f.endsWith(".json")).sort();
	assert.deepEqual(committed, Object.keys(fixtures).sort(), "fixture set drifted — run scripts/export-native-fixtures.ts");
	for (const name of committed) {
		const onDisk = JSON.parse(fs.readFileSync(path.join(NATIVE_FIXTURES_DIR, name), "utf8"));
		assert.deepEqual(onDisk, fixtures[name], `${name} drifted — run scripts/export-native-fixtures.ts`);
	}
});

test("every fixture satisfies the native contract schema", () => {
	for (const [name, value] of Object.entries(fixtures)) {
		if (name === "stream-frames.json") {
			for (const frame of value as unknown[]) assert(Value.Check(NativeStreamFrameSchema, frame), `${name}: ${JSON.stringify([...Value.Errors(NativeStreamFrameSchema, frame)].slice(0, 3))}`);
		} else {
			assert(Value.Check(NativeSessionViewSchema, value), `${name}: ${JSON.stringify([...Value.Errors(NativeSessionViewSchema, value)].slice(0, 3))}`);
		}
	}
});

test("fixtures never leak a pending answer or an unrevealed model solution", () => {
	const pending = fixtures["pending-quiz.view.json"] as { dock: { type: string } };
	assert.equal(pending.dock.type, "question");
	const json = JSON.stringify(pending);
	assert(!json.includes("correctAnswer"));
	assert(!json.includes("innermost"));
});
