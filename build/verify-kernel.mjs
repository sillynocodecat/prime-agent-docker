#!/usr/bin/env node
/**
 * Runtime-stage kernel verification for the Prime Agent container image.
 *
 * Runs inside the final image (during the image build and in acceptance tests)
 * against the copied /opt/prime-agent tree. It proves the baked kernel is
 * complete without uv, network, or a second bootstrap:
 *
 *   - environment contract: PRIME_AGENT_KERNEL_VENV set, PRIME_AGENT_KERNEL_PYTHON
 *     unset, UV_PYTHON_INSTALL_DIR set, uv callable, no uv cache copied;
 *   - the venv Python runs, is the pinned 3.x, and imports rlm, dill, every
 *     current upstream default package, and every bundled Python-backed skill;
 *   - ensureKernelPython with the bundled skills returns immediately: a
 *     decoy `uv` is put first in PATH and would abort the check if invoked,
 *     and .bootstrap-version must stay byte-identical.
 *
 * With --first-start it repeats the no-bootstrap check the way the daemon
 * actually performs it: a fresh container without MCP credentials hides the
 * catalog-gated bundled skills (linear, notion), so the kernel is asked for the
 * default-visible subset. Upstream then finds every requested skill already
 * recorded, executes nothing, and merely rewrites .bootstrap-version to that
 * subset. This mutates the marker, so it belongs in acceptance runs, not in the
 * image build.
 *
 * With --sync-user-skill it additionally creates a throwaway Python-backed
 * user skill and proves PRIME_AGENT_KERNEL_VENV still permits a later sync
 * (needs network for the build backend; never run this during the image
 * build, it mutates the venv).
 */
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const stage = process.env.STAGE_DIR ?? "/opt/prime-agent";
const codingAgent = path.join(stage, "packages", "coding-agent");
const venv = process.env.PRIME_AGENT_KERNEL_VENV;
const pythonInstallDir = process.env.UV_PYTHON_INSTALL_DIR;
const syncUserSkill = process.argv.includes("--sync-user-skill");
const firstStart = process.argv.includes("--first-start");
const EXPECTED_PYTHON = "3.11"; // mirrors upstream bootstrap.ts PYTHON_VERSION

let failed = false;
const check = (ok, message) => {
	console.log(`  ${ok ? "ok  " : "FAIL"} ${message}`);
	if (!ok) failed = true;
	return ok;
};
const under = (target, root) => {
	const resolved = path.resolve(target);
	const prefix = root.endsWith(path.sep) ? root : `${root}${path.sep}`;
	return resolved === root || resolved.startsWith(prefix);
};

console.log("\n==> Kernel environment contract");
check(typeof venv === "string" && existsSync(venv), `PRIME_AGENT_KERNEL_VENV=${venv} exists`);
check(process.env.PRIME_AGENT_KERNEL_PYTHON === undefined, "PRIME_AGENT_KERNEL_PYTHON is not set");
check(typeof pythonInstallDir === "string" && existsSync(pythonInstallDir), `UV_PYTHON_INSTALL_DIR=${pythonInstallDir} exists`);
const uv = spawnSync("uv", ["--version"], { encoding: "utf8" });
check(uv.status === 0, `uv callable: ${(uv.stdout ?? "").trim() || uv.error?.message}`);
const cacheDir = (spawnSync("uv", ["cache", "dir"], { encoding: "utf8" }).stdout ?? "").trim();
check(cacheDir !== "" && !existsSync(cacheDir), `no uv download cache shipped (${cacheDir || "unknown"} absent)`);
check(!existsSync("/root/.cache/uv"), "no /root/.cache/uv in the image");
if (failed) process.exit(1);

const python = path.join(venv, "bin", "python");
console.log("\n==> Venv Python");
const pyVersion = spawnSync(python, ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"], { encoding: "utf8" });
check(pyVersion.status === 0 && pyVersion.stdout.trim() === EXPECTED_PYTHON, `python ${pyVersion.stdout.trim() || "(failed)"} (expected ${EXPECTED_PYTHON})`);
const home = readFileSync(path.join(venv, "pyvenv.cfg"), "utf8").match(/^home\s*=\s*(.+)$/m)?.[1]?.trim();
check(home !== undefined && under(home, pythonInstallDir) && existsSync(home), `pyvenv.cfg home=${home} resolves inside UV_PYTHON_INSTALL_DIR`);

console.log("\n==> Bundled skills through Prime Agent's loader");
const { loadSkillsFromDir, getPythonSkillRuntimeInfo } = await import(path.join(codingAgent, "dist", "index.js"));
const { ensureKernelPython, DEFAULT_RLM_EXTRA_IMPORT_NAMES } = await import(
	path.join(codingAgent, "dist", "core", "kernel", "bootstrap.js")
);
const { skills, diagnostics } = loadSkillsFromDir({ dir: path.join(codingAgent, "dist", "skills"), source: "builtin" });
for (const d of diagnostics) if (d.type === "error") check(false, `skill diagnostic: ${d.message} (${d.path ?? ""})`);
const pythonSkills = getPythonSkillRuntimeInfo(skills);
check(skills.length > 0 && pythonSkills.length > 0, `${skills.length} bundled skills, ${pythonSkills.length} Python-backed`);
const recorded = JSON.parse(readFileSync(path.join(venv, ".bootstrap-version"), "utf8"));
check(recorded.pythonSkills?.length === pythonSkills.length, `.bootstrap-version records ${recorded.pythonSkills?.length ?? 0} skills for ${pythonSkills.length} discovered`);

console.log("\n==> Imports: rlm, dill, current upstream defaults, every bundled Python skill");
const imports = ["rlm", "dill", ...DEFAULT_RLM_EXTRA_IMPORT_NAMES, ...pythonSkills.map((s) => s.importName)];
const importRun = spawnSync(python, ["-c", `import ${imports.join(", ")}; print("ok")`], { encoding: "utf8" });
check(importRun.status === 0 && importRun.stdout.trim() === "ok", `import ${imports.join(", ")}${importRun.status === 0 ? "" : `\n      ${importRun.stderr.trim().split("\n").at(-1)}`}`);

const versionFile = path.join(venv, ".bootstrap-version");

/**
 * Run ensureKernelPython with a decoy `uv` first in PATH. upstream's ensureUv
 * resolves `uv` through process.env.PATH at call time, so if anything tried to
 * execute uv the decoy would exit 99, surface as a per-skill install failure
 * through onProgress, and fail the check.
 */
async function ensureWithoutUv(label, requested) {
	const decoyDir = mkdtempSync(path.join(tmpdir(), "prime-agent-decoy-uv-"));
	const decoy = path.join(decoyDir, "uv");
	writeFileSync(decoy, "#!/bin/sh\necho 'verify-kernel: uv was invoked although the baked kernel must already be complete' >&2\nexit 99\n");
	chmodSync(decoy, 0o755);
	const originalPath = process.env.PATH;
	process.env.PATH = `${decoyDir}:${originalPath}`;
	const started = Date.now();
	let ensured;
	try {
		ensured = await ensureKernelPython({ pythonSkills: requested, onProgress: (m) => check(false, `${label}: unexpected bootstrap progress: ${m}`) });
	} catch (error) {
		check(false, `${label}: ensureKernelPython failed: ${error instanceof Error ? error.message : String(error)}`);
	} finally {
		process.env.PATH = originalPath;
		rmSync(decoyDir, { recursive: true, force: true });
	}
	check(ensured === python, `${label}: returned ${ensured} in ${((Date.now() - started) / 1000).toFixed(1)} s with a decoy uv first in PATH`);
}

console.log("\n==> No second bootstrap: ensureKernelPython with every baked skill must not call uv or touch the venv");
const versionBefore = readFileSync(versionFile, "utf8");
const mtimeBefore = statSync(versionFile).mtimeMs;
await ensureWithoutUv("all baked skills", pythonSkills);
check(readFileSync(versionFile, "utf8") === versionBefore && statSync(versionFile).mtimeMs === mtimeBefore, ".bootstrap-version byte-identical and untouched");

if (firstStart) {
	console.log("\n==> First kernel start as the daemon performs it: catalog-gated skills hidden");
	// MCPManager registers every BUILTIN_MCP_CATALOG entry and, without stored
	// credentials, disables the matching bundled skill directory
	// (`-<server>/SKILL.md`), so agent-session passes only the model-visible
	// skills to the kernel. Mirror that exactly.
	const { BUILTIN_MCP_CATALOG } = await import(path.join(stage, "packages", "ai", "dist", "mcp.js"));
	const gated = new Set(BUILTIN_MCP_CATALOG.map((entry) => entry.server));
	const hidden = pythonSkills.filter((s) => gated.has(path.basename(s.packagePath)));
	const visible = pythonSkills.filter((s) => !gated.has(path.basename(s.packagePath)));
	check(hidden.length > 0 && visible.length > 0, `${hidden.length} gated until authenticated (${hidden.map((s) => s.importName).join(", ")}), ${visible.length} visible by default`);
	await ensureWithoutUv("default-visible skills", visible);
	const after = JSON.parse(readFileSync(versionFile, "utf8"));
	const recordedNow = new Set((after.pythonSkills ?? []).map((s) => s.importName));
	check(
		recordedNow.size === visible.length && visible.every((s) => recordedNow.has(s.importName)),
		`.bootstrap-version rewritten to exactly the ${visible.length} visible skills (upstream's syncPythonSkills records what was requested; nothing was installed or removed)`,
	);
	const stillThere = spawnSync(python, ["-c", `import ${pythonSkills.map((s) => s.importName).join(", ")}; print("ok")`], { encoding: "utf8" });
	check(stillThere.status === 0, "hidden skills remain installed in the venv, so enabling them later only re-registers the editable install");
}

if (syncUserSkill) {
	console.log("\n==> Later sync of a user Python-backed skill through PRIME_AGENT_KERNEL_VENV");
	const skillRoot = mkdtempSync(path.join(tmpdir(), "prime-agent-user-skill-"));
	const skillDir = path.join(skillRoot, "container-probe-skill");
	mkdirSync(path.join(skillDir, "container_probe_skill"), { recursive: true });
	writeFileSync(
		path.join(skillDir, "pyproject.toml"),
		'[project]\nname = "container-probe-skill"\nversion = "0.0.1"\ndependencies = []\n\n[build-system]\nrequires = ["hatchling"]\nbuild-backend = "hatchling.build"\n\n[tool.hatch.build.targets.wheel]\npackages = ["container_probe_skill"]\n',
	);
	writeFileSync(path.join(skillDir, "container_probe_skill", "__init__.py"), 'PROBE = "container-probe-skill installed"\n');
	writeFileSync(
		path.join(skillDir, "SKILL.md"),
		"---\nname: container-probe-skill\ndescription: Throwaway skill proving later Python sync works.\n---\n\n# container-probe-skill\n",
	);
	const userSkill = {
		name: "container-probe-skill",
		importName: "container_probe_skill",
		packagePath: skillDir,
		pyprojectPath: path.join(skillDir, "pyproject.toml"),
	};
	const syncStarted = Date.now();
	try {
		const synced = await ensureKernelPython({ pythonSkills: [...pythonSkills, userSkill], onProgress: (m) => console.log(`  ${m}`) });
		check(synced === python, `sync returned ${synced} in ${((Date.now() - syncStarted) / 1000).toFixed(1)} s`);
		const probe = spawnSync(python, ["-c", "import container_probe_skill; print(container_probe_skill.PROBE)"], { encoding: "utf8" });
		check(probe.status === 0 && probe.stdout.includes("installed"), `user skill importable: ${probe.stdout.trim() || probe.stderr.trim().split("\n").at(-1)}`);
		const after = JSON.parse(readFileSync(versionFile, "utf8"));
		check(after.pythonSkills?.some((s) => s.importName === "container_probe_skill"), ".bootstrap-version now records the user skill");
		const bundledStill = spawnSync(python, ["-c", `import ${pythonSkills.map((s) => s.importName).join(", ")}; print("ok")`], { encoding: "utf8" });
		check(bundledStill.status === 0, "bundled skills still importable after the user sync");
	} catch (error) {
		check(false, `user skill sync failed: ${error instanceof Error ? error.message : String(error)}`);
	} finally {
		rmSync(skillRoot, { recursive: true, force: true });
	}
}

if (failed) process.exit(1);
console.log("\n==> Kernel verified");
