#!/usr/bin/env node
/**
 * Builder-stage kernel bootstrap for the Prime Agent container image.
 *
 * Runs after build-prime-agent.sh has staged the runtime tree, with the same
 * environment the final image will carry:
 *   UV_PYTHON_INSTALL_DIR   uv-managed Python root under the staged tree
 *   PRIME_AGENT_KERNEL_VENV kernel venv path under the staged tree
 *   PRIME_AGENT_KERNEL_PYTHON must be unset (it disables Python-backed skills)
 *
 * It discovers the bundled skills through Prime Agent's own loader and hands
 * every Python-backed one to upstream's ensureKernelPython, so editable
 * installs and the recorded pyproject hashes point at the final /opt paths and
 * survive the copy into the runtime stage. Everything it writes lives under the
 * staged tree; the uv download cache stays outside it and is never copied.
 */
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";

const stage = process.env.STAGE_DIR ?? "/opt/prime-agent";
const codingAgent = path.join(stage, "packages", "coding-agent");
const venv = process.env.PRIME_AGENT_KERNEL_VENV;
const pythonInstallDir = process.env.UV_PYTHON_INSTALL_DIR;
// Upstream pins this in src/core/kernel/bootstrap.ts (PYTHON_VERSION); it is not
// exported, so a bump there must be mirrored here and re-verified.
const EXPECTED_PYTHON = "3.11";

let failed = false;
const check = (ok, message) => {
	console.log(`  ${ok ? "ok  " : "FAIL"} ${message}`);
	if (!ok) failed = true;
	return ok;
};
const fail = (message) => {
	console.error(`bootstrap-kernel: ${message}`);
	process.exit(1);
};
const under = (target, root) => {
	const resolved = path.resolve(target);
	const prefix = root.endsWith(path.sep) ? root : `${root}${path.sep}`;
	return resolved === root || resolved.startsWith(prefix);
};

console.log("\n==> Kernel bootstrap preconditions");
if (!venv) fail("PRIME_AGENT_KERNEL_VENV must be set");
if (!pythonInstallDir) fail("UV_PYTHON_INSTALL_DIR must be set");
check(under(venv, stage), `PRIME_AGENT_KERNEL_VENV=${venv} is under ${stage}`);
check(under(pythonInstallDir, stage), `UV_PYTHON_INSTALL_DIR=${pythonInstallDir} is under ${stage}`);
check(process.env.PRIME_AGENT_KERNEL_PYTHON === undefined, "PRIME_AGENT_KERNEL_PYTHON is not set");
const uv = spawnSync("uv", ["--version"], { encoding: "utf8" });
check(uv.status === 0, `uv on PATH: ${(uv.stdout ?? "").trim() || uv.error?.message}`);
check(existsSync(path.join(codingAgent, "dist", "index.js")), "staged coding-agent dist present");
check(existsSync(path.join(codingAgent, "dist", "prime-agent-runtime", "pyproject.toml")), "staged dist/prime-agent-runtime present");
const cacheDir = process.env.UV_CACHE_DIR;
check(cacheDir === undefined || !under(cacheDir, stage), `uv cache (${cacheDir ?? "default"}) is outside the staged tree`);
if (failed) process.exit(1);

console.log("\n==> Discovering bundled skills with Prime Agent's loader");
const { loadSkillsFromDir, getPythonSkillRuntimeInfo } = await import(path.join(codingAgent, "dist", "index.js"));
const { ensureKernelPython, DEFAULT_RLM_EXTRA_IMPORT_NAMES } = await import(
	path.join(codingAgent, "dist", "core", "kernel", "bootstrap.js")
);
const bundledSkillsDir = path.join(codingAgent, "dist", "skills");
const { skills, diagnostics } = loadSkillsFromDir({ dir: bundledSkillsDir, source: "builtin" });
for (const d of diagnostics) {
	console.log(`  ${d.type === "error" ? "FAIL" : "warn"} skill diagnostic: ${d.message}${d.path ? ` (${d.path})` : ""}`);
	if (d.type === "error") failed = true;
}
check(skills.length > 0, `${skills.length} bundled skills: ${skills.map((s) => s.name).join(", ")}`);
const pythonSkills = getPythonSkillRuntimeInfo(skills);
check(pythonSkills.length > 0, `${pythonSkills.length} Python-backed: ${pythonSkills.map((s) => s.importName).join(", ")}`);
for (const s of pythonSkills) {
	check(under(s.packagePath, codingAgent) && under(s.pyprojectPath, codingAgent), `${s.name}: package path is final (${s.packagePath})`);
}
if (failed) process.exit(1);

console.log("\n==> Bootstrapping the kernel venv");
const started = Date.now();
const python = await ensureKernelPython({ pythonSkills, onProgress: (m) => console.log(`  ${m}`) });
console.log(`  kernel python: ${python} (${((Date.now() - started) / 1000).toFixed(1)} s)`);
check(under(python, venv), "returned interpreter lives in PRIME_AGENT_KERNEL_VENV");

console.log("\n==> Verifying the bootstrapped venv");
const versionFile = path.join(venv, ".bootstrap-version");
check(existsSync(versionFile), ".bootstrap-version written");
const version = JSON.parse(readFileSync(versionFile, "utf8"));
check(typeof version.schema === "number" && typeof version.runtime === "string", `schema ${version.schema}, runtime ${String(version.runtime).slice(0, 19)}…`);
check(Array.isArray(version.pythonSkills) && version.pythonSkills.length === pythonSkills.length, `${version.pythonSkills?.length ?? 0} skills recorded in .bootstrap-version`);
for (const s of version.pythonSkills ?? []) {
	check(under(s.packagePath, stage) && under(s.pyprojectPath, stage), `recorded ${s.importName} -> ${s.packagePath}`);
}

const pyvenv = readFileSync(path.join(venv, "pyvenv.cfg"), "utf8");
const home = pyvenv.match(/^home\s*=\s*(.+)$/m)?.[1]?.trim();
check(home !== undefined && under(home, pythonInstallDir), `pyvenv.cfg home=${home} is inside UV_PYTHON_INSTALL_DIR`);
const realPython = realpathSync(python);
check(under(realPython, pythonInstallDir), `venv python resolves to ${realPython}`);
const pyVersion = spawnSync(python, ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"], { encoding: "utf8" });
check(pyVersion.stdout.trim() === EXPECTED_PYTHON, `kernel Python ${pyVersion.stdout.trim()} (expected ${EXPECTED_PYTHON})`);

// Nothing inside the venv may point at a path that the runtime stage will not
// have: only the staged tree itself is copied. Scan every file that can carry
// an absolute install path.
const srcDir = process.env.SRC_DIR ?? "/src";
const suspicious = [];
const scan = (dir) => {
	for (const entry of readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (entry.name === "__pycache__") continue;
			scan(full);
			continue;
		}
		if (!/\.(pth|egg-link|txt|json|cfg)$/.test(entry.name) && entry.name !== "RECORD") continue;
		if (statSync(full).size > 4 * 1024 * 1024) continue;
		const text = readFileSync(full, "utf8");
		for (const line of text.split("\n")) {
			const abs = line.match(/(?:^|["'\s=:])(\/[^"'\s]+)/);
			if (!abs) continue;
			const p = abs[1];
			if (under(p, stage) || under(p, "/usr") || under(p, "/bin") || under(p, "/lib") || p.startsWith("/dev") || p.startsWith("/proc")) continue;
			if (under(p, srcDir) || p.startsWith("/root") || p.startsWith("/tmp") || p.startsWith("/home")) {
				suspicious.push(`${path.relative(venv, full)}: ${p}`);
			}
		}
	}
};
scan(venv);
check(suspicious.length === 0, `no venv reference to the builder-only tree${suspicious.length ? `:\n      ${suspicious.slice(0, 8).join("\n      ")}` : ""}`);

console.log("\n==> Import checks (defaults + every bundled Python skill)");
const defaults = ["rlm", "dill", ...DEFAULT_RLM_EXTRA_IMPORT_NAMES];
const imports = [...defaults, ...pythonSkills.map((s) => s.importName)];
const importRun = spawnSync(python, ["-c", `import ${imports.join(", ")}; print("ok")`], { encoding: "utf8" });
check(importRun.status === 0 && importRun.stdout.trim() === "ok", `import ${imports.join(", ")}${importRun.status === 0 ? "" : `\n      ${importRun.stderr.trim().split("\n").at(-1)}`}`);

console.log("\n==> Idempotence: a second call must not touch the venv");
const before = statSync(versionFile).mtimeMs;
const again = Date.now();
const python2 = await ensureKernelPython({ pythonSkills, onProgress: (m) => console.log(`  unexpected progress: ${m}`) });
check(python2 === python && statSync(versionFile).mtimeMs === before, `second ensureKernelPython returned in ${((Date.now() - again) / 1000).toFixed(1)} s without rewriting .bootstrap-version`);

console.log("\n==> uv cache stays out of the staged tree");
const cacheProbe = spawnSync("uv", ["cache", "dir"], { encoding: "utf8" });
const resolvedCache = (cacheProbe.stdout ?? "").trim();
check(resolvedCache !== "" && !under(resolvedCache, stage), `uv cache dir: ${resolvedCache || "(unknown)"}`);

if (failed) process.exit(1);
console.log(`\n==> Kernel ready at ${venv}`);
