/**
 * Container-build assertions for the two behaviors of prime-agent-container.patch.
 *
 * This file is copied into packages/coding-agent/test/ by build/build-prime-agent.sh
 * and run with upstream's vitest before packaging. It is not part of upstream.
 */
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
	CONTAINER_CONFIG_DIR_ENV,
	containerConfigDir,
	withContainerAppendSystemPrompt,
	withContainerSkills,
} from "../src/cli/container-config.js";
import { DEFAULT_IDLE_EVICTION_MINUTES, SettingsManager } from "../src/core/settings-manager.js";
import { idleEvictionSweepIntervalMs } from "../src/modes/daemon/daemon-supervisor.js";

describe("container build: managed config injection", () => {
	let configDir: string;

	beforeEach(() => {
		configDir = mkdtempSync(join(tmpdir(), "prime-agent-container-config-"));
	});

	afterEach(() => {
		rmSync(configDir, { recursive: true, force: true });
	});

	it("leaves every input untouched when the variable is unset (non-container behavior)", () => {
		const env: NodeJS.ProcessEnv = {};
		expect(containerConfigDir(env)).toBeUndefined();
		expect(withContainerAppendSystemPrompt(undefined, env)).toBeUndefined();
		expect(withContainerSkills(undefined, env)).toBeUndefined();
		const append = ["Be brief."];
		const skills = ["/work/.prime/agent/skills/local"];
		expect(withContainerAppendSystemPrompt(append, env)).toBe(append);
		expect(withContainerSkills(skills, env)).toBe(skills);
	});

	it("ignores relative, empty, and newline-containing directories", () => {
		for (const value of ["", "etc/prime-agent", "relative", `${configDir}\n/evil`]) {
			const env = { [CONTAINER_CONFIG_DIR_ENV]: value };
			expect(containerConfigDir(env)).toBeUndefined();
			expect(withContainerAppendSystemPrompt(undefined, env)).toBeUndefined();
			expect(withContainerSkills(undefined, env)).toBeUndefined();
		}
	});

	it("keeps inputs untouched when the managed entries do not exist, so upstream discovery still runs", () => {
		const env = { [CONTAINER_CONFIG_DIR_ENV]: configDir };
		expect(withContainerAppendSystemPrompt(undefined, env)).toBeUndefined();
		expect(withContainerSkills(undefined, env)).toBeUndefined();
		const append = ["user"];
		expect(withContainerAppendSystemPrompt(append, env)).toBe(append);
	});

	it("prepends the managed APPEND_SYSTEM.md and skills directory ahead of user entries", () => {
		const managedPrompt = join(configDir, "APPEND_SYSTEM.md");
		const managedSkills = join(configDir, "skills");
		writeFileSync(managedPrompt, "# managed\n");
		mkdirSync(managedSkills);
		const env = { [CONTAINER_CONFIG_DIR_ENV]: configDir };

		expect(withContainerAppendSystemPrompt(undefined, env)).toEqual([managedPrompt]);
		expect(withContainerAppendSystemPrompt(["user one", "/work/APPEND.md"], env)).toEqual([
			managedPrompt,
			"user one",
			"/work/APPEND.md",
		]);
		expect(withContainerSkills(undefined, env)).toEqual([managedSkills]);
		expect(withContainerSkills(["/work/.prime/agent/skills/x"], env)).toEqual([
			managedSkills,
			"/work/.prime/agent/skills/x",
		]);
	});

	it("ignores a managed entry of the wrong type (a skills file, an APPEND_SYSTEM.md directory)", () => {
		writeFileSync(join(configDir, "skills"), "not a directory\n");
		mkdirSync(join(configDir, "APPEND_SYSTEM.md"));
		const env = { [CONTAINER_CONFIG_DIR_ENV]: configDir };
		expect(withContainerSkills(undefined, env)).toBeUndefined();
		expect(withContainerAppendSystemPrompt(undefined, env)).toBeUndefined();
		const user = ["user"];
		expect(withContainerSkills(user, env)).toBe(user);
	});

	it("injects each entry independently and never duplicates an already-listed managed path", () => {
		const managedPrompt = join(configDir, "APPEND_SYSTEM.md");
		writeFileSync(managedPrompt, "# managed\n");
		const env = { [CONTAINER_CONFIG_DIR_ENV]: configDir };

		expect(withContainerAppendSystemPrompt(["x", managedPrompt], env)).toEqual([managedPrompt, "x"]);
		// skills/ does not exist yet: explicit skills stay exactly as given
		const skills = ["/work/skill"];
		expect(withContainerSkills(skills, env)).toBe(skills);
	});
});

describe("container build: idle eviction default", () => {
	let projectDir: string;
	let agentDir: string;

	beforeEach(() => {
		projectDir = mkdtempSync(join(tmpdir(), "prime-agent-container-project-"));
		agentDir = mkdtempSync(join(tmpdir(), "prime-agent-container-agent-"));
	});

	afterEach(() => {
		rmSync(projectDir, { recursive: true, force: true });
		rmSync(agentDir, { recursive: true, force: true });
	});

	it("defaults to 0.1 minutes so upstream's 60-second minimum sweep can passivate an idle worker", () => {
		expect(DEFAULT_IDLE_EVICTION_MINUTES).toBe(0.1);
		expect(SettingsManager.create(projectDir, agentDir).getIdleEvictionMinutes()).toBe(0.1);
		expect(idleEvictionSweepIntervalMs(0.1)).toBe(60_000);
	});

	it("lets an explicit user setting win, including off", () => {
		writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ idleEvictionMinutes: 45 }));
		expect(SettingsManager.create(projectDir, agentDir).getIdleEvictionMinutes()).toBe(45);
		expect(idleEvictionSweepIntervalMs(45)).toBe(5 * 60_000);

		writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ idleEvictionMinutes: "off" }));
		expect(SettingsManager.create(projectDir, agentDir).getIdleEvictionMinutes()).toBe("off");
	});

	it("still falls back to the container default for invalid values", () => {
		writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ idleEvictionMinutes: -5 }));
		expect(SettingsManager.create(projectDir, agentDir).getIdleEvictionMinutes()).toBe(0.1);
	});
});
