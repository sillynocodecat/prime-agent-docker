/**
 * Lifecycle-gate drift check (TODO §5/§9). Runs in the image's throwaway
 * `verify` stage, so every image build — and therefore every CI run for a new
 * upstream release — fails if the public JSON the service controller relies on
 * changes shape or meaning.
 *
 * It starts the real staged daemon exactly as the service does (`--mode daemon`
 * child, default socket under $TMPDIR), drives the four public commands the
 * controller uses, and feeds their real output into the controller's own
 * interpreters imported from service.mjs:
 *
 *   status --json                → one current default with our version/build,
 *                                  sessionCount 0, no tracked workers ⇒ quiescent
 *   list --json                  → { sessions: [] }
 *   schedule list --all --json   → { jobs: [] }, no unknown status
 *   shutdown --force --json      → { stopped: [...], failed: [] }
 *   status --json (after)        → [] (a graceful shutdown unlinks the socket)
 *
 * Field-level assertions on DaemonInfo pin the exact keys the controller reads.
 * Nothing here needs credentials, a model, or the launcher contract.
 */
import { execFile, spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import {
	BUNDLE,
	interpretList,
	interpretSchedule,
	interpretShutdown,
	interpretStatus,
} from "/usr/local/lib/prime-agent-container/service.mjs";

const execFileP = promisify(execFile);
let failed = 0;
const ok = (m) => console.log(`  ok   ${m}`);
const fail = (m) => {
	console.log(`  FAIL ${m}`);
	failed++;
};
const check = (cond, m) => (cond ? ok(m) : fail(m));

const version = process.env.PRIME_AGENT_VERSION;
const buildId = process.env.PRIME_AGENT_BUILD_ID;
if (!version || !buildId) throw new Error("PRIME_AGENT_VERSION and PRIME_AGENT_BUILD_ID are required");
if (process.env.PRIME_AGENT_CONTAINER_CLIENT !== undefined) throw new Error("client marker must not be set");

const home = mkdtempSync(path.join(tmpdir(), "lifecycle-json-"));
const agentDir = path.join(home, "agent");
const cwd = path.join(home, "work");
mkdirSync(agentDir, { recursive: true });
mkdirSync(cwd, { recursive: true });
const env = { ...process.env, HOME: home, PRIME_AGENT_CODING_AGENT_DIR: agentDir };
delete env.PRIME_AGENT_CONTAINER_CLIENT;

async function publicJson(args) {
	const { stdout } = await execFileP(process.execPath, [BUNDLE, ...args], { cwd, env, timeout: 10_000, killSignal: "SIGKILL", encoding: "utf8" });
	try {
		return JSON.parse(stdout);
	} catch {
		throw new Error(`${args.join(" ")} printed non-JSON on stdout: ${JSON.stringify(stdout.slice(0, 200))}`);
	}
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const expected = { version, buildId };

console.log("\n==> Lifecycle JSON drift check against the real daemon");
const before = interpretStatus(await publicJson(["status", "--json"]), expected);
check(before.ok && before.empty, "status --json with no daemon → [] (public probes never spawn a daemon)");

const daemon = spawn(process.execPath, [BUNDLE, "--mode", "daemon"], { cwd, env, stdio: ["ignore", "ignore", "pipe"] });
let daemonStderr = "";
daemon.stderr.on("data", (d) => (daemonStderr += d));
let exited = null;
daemon.on("exit", (code, signal) => (exited = { code, signal }));

let status;
const deadline = Date.now() + 30_000;
while (Date.now() < deadline) {
	status = interpretStatus(await publicJson(["status", "--json"]), expected);
	if (status.ok && status.defaultState === "present") break;
	await sleep(500);
}
try {
	check(status?.ok, "status --json is an array of well-formed entries");
	check(status?.defaultState === "present", `default daemon current with version ${version} and buildId ${buildId} (state=${status?.defaultState}, ${status?.reason || "no reason"})`);
	check(status?.entries.length === 1, `exactly one daemon entry (${status?.entries.length})`);
	const info = status?.entries[0] ?? {};
	for (const [key, type] of [
		["version", "string"],
		["protocolVersion", "number"],
		["schemaId", "string"],
		["buildId", "string"],
		["status", "string"],
		["isDefault", "boolean"],
		["sessionCount", "number"],
		["pid", "number"],
	]) {
		check(typeof info[key] === type, `DaemonInfo.${key} is a ${type} (${JSON.stringify(info[key])})`);
	}
	// v0.9.1 sets hasTrackedWorkers only when descriptors exist and omits it
	// otherwise; the controller treats anything but `true` as untracked.
	check(info.hasTrackedWorkers === undefined || typeof info.hasTrackedWorkers === "boolean", `DaemonInfo.hasTrackedWorkers is boolean or omitted (${JSON.stringify(info.hasTrackedWorkers)})`);
	check(info.hasTrackedWorkers !== true, "no tracked workers for a fresh daemon");
	check(info.status === "current", "DaemonInfo.status === \"current\" for a matching CLI");
	check(status?.quiescent === true && status?.tracked === false, "controller reads the fresh daemon as quiescent and untracked");

	const list = await publicJson(["list", "--json"]);
	const li = interpretList(list);
	check(li.ok && li.empty, `list --json → { sessions: [] } (${JSON.stringify(list).slice(0, 80)})`);
	check(Object.keys(list).join(",") === "sessions", "list --json has exactly the sessions key");

	const sched = await publicJson(["schedule", "list", "--all", "--json"]);
	const si = interpretSchedule(sched);
	check(si.ok && !si.active && si.count === 0, `schedule list --all --json → { jobs: [] } (${JSON.stringify(sched).slice(0, 80)})`);

	const shut = await publicJson(["shutdown", "--force", "--json"]);
	const sh = interpretShutdown(shut);
	check(sh.ok, `shutdown --force --json → failed: [] (${JSON.stringify(shut).slice(0, 120)})`);
	check(Array.isArray(shut.stopped) && shut.stopped.length === 1, "shutdown stopped exactly one daemon");

	let after;
	const d2 = Date.now() + 15_000;
	while (Date.now() < d2) {
		after = interpretStatus(await publicJson(["status", "--json"]), expected);
		if (after.ok && after.empty && exited) break;
		await sleep(500);
	}
	check(after?.ok && after?.empty, "status --json converges to [] after a graceful shutdown (socket unlinked)");
	check(exited !== null && exited.code === 0, `daemon child exited cleanly (${JSON.stringify(exited)})`);
} finally {
	if (exited === null) {
		daemon.kill("SIGKILL");
		await sleep(500);
	}
	rmSync(home, { recursive: true, force: true });
}
if (failed) {
	console.error(`verify-lifecycle-json: ${failed} check(s) failed\n--- daemon stderr ---\n${daemonStderr.slice(-2000)}`);
	process.exit(1);
}
console.log("verify-lifecycle-json: all checks passed");
