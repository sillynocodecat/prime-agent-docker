#!/usr/bin/env node
/**
 * Prime Agent container service controller (TODO §4/§5). Image ENTRYPOINT.
 *
 * Runs one upstream default daemon as a child, publishes readiness, keeps the
 * container alive while clients, resident/tracked workers or active schedules
 * exist, and stops it only after upstream's own idle passivation has left the
 * supervisor empty. Uses the Node standard library and public CLI JSON commands
 * only; every command runs the staged bundle directly, never the client
 * wrapper, so service work can never create client or manual-shutdown markers.
 *
 * Exit codes: 0 proven automatic quiescence, 75 handled manual shutdown/SIGTERM,
 * 70 startup or launcher-contract failure. Anything else is unclean.
 *
 *   node service.mjs              run the service
 *   node service.mjs --self-test  run the in-process state-machine self-test
 */
import { execFile, spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";

export const RUN_DIR = "/run/prime-agent-container";
export const STAGE_DIR = "/opt/prime-agent";
export const BUNDLE = `${STAGE_DIR}/packages/coding-agent/dist/bundle/cli.js`;
const PACKAGE_JSON = `${STAGE_DIR}/packages/coding-agent/package.json`;
const TMPFS_MAGIC = 0x01021994;

export const EXIT_QUIESCENT = 0;
export const EXIT_STARTUP_FAILURE = 70;
export const EXIT_MANUAL_STOP = 75;

export const DEFAULT_TIMING = Object.freeze({
	pollMs: 5_000,
	probeTimeoutMs: 10_000,
	startupTimeoutMs: 30_000,
	firstClientGraceMs: 60_000,
	quiescentSamples: 3,
	restartBackoffMs: [1_000, 2_000, 5_000],
	restartBackoffCapMs: 30_000,
	diagnosticIntervalMs: 60_000,
	shutdownConvergeMs: 10_000,
	daemonExitWaitMs: 10_000,
});

const KNOWN_JOB_STATUSES = new Set(["active", "paused", "completed", "cancelled"]);

// ---------------------------------------------------------------------------
// Pure interpretation of public CLI JSON. Anything that is not exactly the
// expected shape is "uncertain", never "quiescent".
// ---------------------------------------------------------------------------

export function interpretStatus(json, expected) {
	const result = {
		ok: false,
		entries: [],
		defaultPresent: false,
		defaultPid: undefined,
		foreignDefault: false,
		quiescent: false,
		tracked: false,
		empty: false,
		reason: "",
	};
	if (!Array.isArray(json)) {
		result.reason = "status --json is not an array";
		return result;
	}
	for (const entry of json) {
		if (!entry || typeof entry !== "object" || typeof entry.status !== "string" || typeof entry.isDefault !== "boolean") {
			result.reason = "status entry has an unexpected shape";
			return result;
		}
	}
	result.ok = true;
	result.entries = json;
	result.empty = json.length === 0;
	// The default socket's state decides recovery:
	//   present     current daemon with our version/build → adopt or keep
	//   foreign     current-but-other-build, stale, or anything unknown → never restart over it
	//   orphan      socket file left by a dead daemon → restart (upstream clears the file)
	//   unreachable a live process holds the socket but does not answer → wait
	//   none        no default socket at all → restart
	const defaults = json.filter((e) => e.isDefault);
	let defaultState = "none";
	if (defaults.length === 1) {
		const d = defaults[0];
		if (d.status === "current") {
			defaultState = d.version === expected.version && d.buildId === expected.buildId ? "present" : "foreign";
		} else if (d.status === "orphan-file") {
			defaultState = "orphan";
		} else if (d.status === "unreachable") {
			defaultState = "unreachable";
		} else {
			defaultState = "foreign";
		}
	} else if (defaults.length > 1) {
		defaultState = "foreign";
	}
	result.defaultState = defaultState;
	result.defaultPresent = defaultState === "present";
	result.foreignDefault = defaultState === "foreign";
	if (defaultState === "present") {
		result.defaultPid = typeof defaults[0].pid === "number" ? defaults[0].pid : undefined;
	} else if (defaults.length > 0) {
		result.reason = `default daemon is ${defaults.map((e) => `${e.status}/${e.version ?? "?"}/${e.buildId ?? "?"}`).join(",")}, expected current/${expected.version}/${expected.buildId}`;
	}
	result.tracked = json.some(
		(e) => e.hasTrackedWorkers === true || (typeof e.sessionCount === "number" && e.sessionCount > 0),
	);
	result.quiescent =
		json.length > 0 &&
		json.every((e) => e.status === "current" && e.sessionCount === 0 && e.hasTrackedWorkers !== true);
	return result;
}

export function interpretList(json) {
	if (!json || typeof json !== "object" || !Array.isArray(json.sessions)) {
		return { ok: false, empty: false, count: 0, reason: "list --json has no sessions array" };
	}
	return { ok: true, empty: json.sessions.length === 0, count: json.sessions.length, reason: "" };
}

export function interpretSchedule(json) {
	if (!json || typeof json !== "object" || !Array.isArray(json.jobs)) {
		return { ok: false, active: false, count: 0, reason: "schedule list --json has no jobs array" };
	}
	let active = false;
	for (const job of json.jobs) {
		if (!job || typeof job !== "object" || typeof job.status !== "string" || !KNOWN_JOB_STATUSES.has(job.status)) {
			return { ok: false, active: false, count: json.jobs.length, reason: "scheduled job has an unknown status" };
		}
		if (job.status === "active") active = true;
	}
	return { ok: true, active, count: json.jobs.length, reason: "" };
}

export function interpretShutdown(json) {
	if (!json || typeof json !== "object" || !Array.isArray(json.stopped) || !Array.isArray(json.failed)) {
		return { ok: false, failed: [], reason: "shutdown --json has no stopped/failed arrays" };
	}
	return { ok: json.failed.length === 0, failed: json.failed, reason: json.failed.length ? "shutdown reported failures" : "" };
}

/** Parse /proc/<pid>/stat: state (field 3) and start time (field 22). */
export function parseProcStat(text) {
	const close = text.lastIndexOf(")");
	if (close < 0) return undefined;
	const rest = text.slice(close + 2).split(" ");
	if (rest.length < 20) return undefined;
	return { state: rest[0], starttime: rest[19] };
}

// ---------------------------------------------------------------------------
// Controller state machine. `deps` is injectable so the self-test can drive it
// with fakes and a virtual clock.
// ---------------------------------------------------------------------------

export function createController(deps, timing = DEFAULT_TIMING) {
	const state = {
		phase: "starting", // starting | running | manual | terminating | exited
		armed: false,
		readyAt: undefined,
		quiescentStreak: 0,
		exitCode: undefined,
		daemon: {
			pid: undefined,
			child: undefined,
			adopted: false,
			exitedAt: undefined,
			restartAttempt: 0,
			restartAt: undefined,
		},
		manualHonored: false,
		lastLeaseCount: 0,
	};
	const lastDiagnostic = new Map();
	const suppressed = new Map();

	const log = (message) => deps.log(message);
	const diag = (key, message) => {
		const now = deps.now();
		const last = lastDiagnostic.get(key);
		if (last !== undefined && now - last < timing.diagnosticIntervalMs) {
			suppressed.set(key, (suppressed.get(key) ?? 0) + 1);
			return;
		}
		const n = suppressed.get(key) ?? 0;
		suppressed.delete(key);
		lastDiagnostic.set(key, now);
		log(n > 0 ? `${message} (${n} similar message${n === 1 ? "" : "s"} suppressed)` : message);
	};
	const finish = (code, why) => {
		if (state.phase === "exited") return;
		log(`exiting with code ${code}: ${why}`);
		state.phase = "exited";
		state.exitCode = code;
		deps.exit(code);
	};

	function spawnDaemon() {
		const child = deps.daemon.spawn((code, signal) => noteDaemonExit(child, code, signal));
		state.daemon.child = child;
		state.daemon.pid = child.pid;
		state.daemon.adopted = false;
		state.daemon.exitedAt = undefined;
		log(`daemon started (pid ${child.pid})`);
		return child;
	}

	function noteDaemonExit(child, code, signal) {
		if (state.daemon.child !== child) return;
		state.daemon.child = undefined;
		state.daemon.pid = undefined;
		state.daemon.exitedAt = deps.now();
		if (state.phase === "terminating" || state.phase === "exited") return;
		diag("daemon-exit", `daemon exited (code ${code ?? "null"}, signal ${signal ?? "none"})`);
	}

	async function probeStatus() {
		const res = await deps.probes.status();
		if (!res.ok) return { ok: false, reason: res.error ?? "status probe failed", entries: [] };
		return interpretStatus(res.json, deps.expected);
	}

	async function startup() {
		log(`starting Prime Agent ${deps.expected.version} (${deps.expected.buildId})`);
		spawnDaemon();
		const deadline = deps.now() + timing.startupTimeoutMs;
		while (deps.now() < deadline) {
			const st = await probeStatus();
			if (st.ok && st.defaultPresent && st.entries.length === 1) {
				state.phase = "running";
				state.readyAt = deps.now();
				deps.markers.create("ready", JSON.stringify({ daemonPid: st.defaultPid ?? state.daemon.pid, readyAt: new Date(state.readyAt).toISOString(), version: deps.expected.version, buildId: deps.expected.buildId }));
				log(`ready: default daemon current (pid ${st.defaultPid ?? state.daemon.pid ?? "?"}); first-client grace ${timing.firstClientGraceMs / 1000}s`);
				return true;
			}
			if (st.ok && st.foreignDefault) {
				finish(EXIT_STARTUP_FAILURE, `a foreign daemon owns the default socket: ${st.reason}`);
				return false;
			}
			if (state.daemon.child === undefined && state.daemon.exitedAt !== undefined) {
				finish(EXIT_STARTUP_FAILURE, "daemon exited during startup");
				return false;
			}
			await deps.sleep(500);
		}
		finish(EXIT_STARTUP_FAILURE, `daemon did not become ready within ${timing.startupTimeoutMs / 1000}s`);
		return false;
	}

	function backoffMs(attempt) {
		const table = timing.restartBackoffMs;
		return attempt < table.length ? table[attempt] : timing.restartBackoffCapMs;
	}

	/** Daemon absent outside our own shutdown paths: adopt a replacement or restart with backoff. */
	function recoverDaemon(st, now) {
		const defaultState = st.ok ? st.defaultState : "unknown";
		if (defaultState === "present") {
			if (state.daemon.child === undefined && !state.daemon.adopted) {
				state.daemon.adopted = true;
				state.daemon.pid = st.defaultPid;
				log(`adopted replacement default daemon (pid ${st.defaultPid ?? "?"})`);
			}
			state.daemon.restartAttempt = 0;
			state.daemon.restartAt = undefined;
			return;
		}
		if (defaultState === "foreign") {
			diag("foreign-daemon", `not restarting: ${st.reason}`);
			return;
		}
		if (state.daemon.child !== undefined) return; // our child is alive; it is still binding or status just failed
		if (defaultState === "unreachable") {
			// A live process (a worker-elected replacement booting, or a hung one)
			// holds the default socket. Restarting would only lose the socket
			// lease race; wait for it to become current or an orphan file.
			diag("daemon-unreachable", "default socket is held by an unreachable process; waiting");
			state.daemon.restartAt = undefined;
			return;
		}
		if (defaultState === "orphan") diag("daemon-orphan", "default socket file has no listener; restarting");
		if (state.daemon.restartAt === undefined) {
			state.daemon.restartAt = now + backoffMs(state.daemon.restartAttempt);
			diag("daemon-restart", `default daemon absent; restarting in ${(state.daemon.restartAt - now) / 1000}s (attempt ${state.daemon.restartAttempt + 1})`);
			return;
		}
		if (now < state.daemon.restartAt) return;
		state.daemon.restartAttempt += 1;
		state.daemon.restartAt = undefined;
		state.daemon.adopted = false;
		spawnDaemon();
	}

	function manualLeaseLive(manual, leases) {
		return leases.some((l) => l.live && l.pid === manual.pid && l.starttime === manual.starttime) || deps.processAlive(manual.pid, manual.starttime);
	}

	async function finalShutdown() {
		const res = await deps.probes.shutdown();
		const sd = res.ok ? interpretShutdown(res.json) : { ok: false, reason: res.error ?? "shutdown probe failed" };
		if (!sd.ok) return { ok: false, reason: sd.reason };
		const deadline = deps.now() + timing.shutdownConvergeMs;
		let converged = false;
		while (deps.now() <= deadline) {
			const st = await probeStatus();
			if (st.ok && st.entries.length === 0) {
				converged = true;
				break;
			}
			await deps.sleep(500);
		}
		if (!converged) return { ok: false, reason: "public status did not converge to an empty array" };
		const childDeadline = deps.now() + timing.daemonExitWaitMs;
		while (state.daemon.child !== undefined && deps.now() <= childDeadline) await deps.sleep(250);
		if (state.daemon.child !== undefined) return { ok: false, reason: "daemon child still running after shutdown" };
		return { ok: true, reason: "" };
	}

	async function step() {
		if (state.phase === "exited" || state.phase === "terminating" || state.phase === "starting") return;
		const now = deps.now();
		const leases = deps.leases();
		const live = leases.filter((l) => l.live);
		if (live.length !== state.lastLeaseCount) {
			log(`${live.length} live client lease${live.length === 1 ? "" : "s"}`);
			state.lastLeaseCount = live.length;
		}
		if (live.length > 0 && !state.armed) {
			state.armed = true;
			log("armed by a live client");
		}

		const st = await probeStatus();
		if (st.ok && st.tracked && !state.armed) {
			state.armed = true;
			log("armed by a resident/tracked worker");
		}

		// Manual shutdown marker: never act while the initiating client is alive.
		const manual = deps.markers.readManual();
		if (manual !== undefined) {
			if (manualLeaseLive(manual, leases)) {
				state.quiescentStreak = 0;
				diag("manual-pending", `manual shutdown in progress (client pid ${manual.pid})`);
				return;
			}
			if (st.ok && st.defaultPresent) {
				deps.markers.remove("manual-shutdown");
				log("manual shutdown marker cleared: the daemon is still reachable (shutdown cancelled or failed)");
			} else if (!state.manualHonored) {
				state.manualHonored = true;
				state.phase = "manual";
				log("manual shutdown honored: daemon gone, not restarting; waiting for remaining clients");
			}
		}
		if (state.manualHonored) {
			if (live.length === 0) finish(EXIT_MANUAL_STOP, "manual shutdown complete");
			else diag("manual-wait", `manual shutdown: waiting for ${live.length} client lease(s)`);
			return;
		}

		// Daemon liveness: restart or adopt outside stopping/manual/terminating.
		const daemonMissing =
			state.daemon.child === undefined || (st.ok && (st.defaultState === "none" || st.defaultState === "orphan"));
		if (daemonMissing) {
			state.quiescentStreak = 0;
			recoverDaemon(st, now);
			return;
		}
		if (st.ok && st.defaultPresent) {
			state.daemon.restartAttempt = 0;
			state.daemon.restartAt = undefined;
		}

		// Quiescence gate.
		if (!state.armed && state.readyAt !== undefined && now - state.readyAt < timing.firstClientGraceMs) {
			state.quiescentStreak = 0;
			return;
		}
		const [listRes, schedRes] = [await deps.probes.list(), await deps.probes.schedule()];
		const list = listRes.ok ? interpretList(listRes.json) : { ok: false, empty: false, reason: listRes.error ?? "list probe failed" };
		const sched = schedRes.ok ? interpretSchedule(schedRes.json) : { ok: false, active: false, reason: schedRes.error ?? "schedule probe failed" };
		if (((list.ok && !list.empty) || (sched.ok && sched.active)) && !state.armed) {
			state.armed = true;
			log(list.ok && !list.empty ? "armed by a visible session" : "armed by an active schedule");
		}
		const quiescent = live.length === 0 && st.ok && st.defaultPresent && st.quiescent && list.ok && list.empty && sched.ok && !sched.active;
		if (!quiescent) {
			if (state.quiescentStreak > 0) log("quiescence streak reset");
			state.quiescentStreak = 0;
			if (!st.ok) diag("status-uncertain", `keeping alive: ${st.reason}`);
			else if (!list.ok) diag("list-uncertain", `keeping alive: ${list.reason}`);
			else if (!sched.ok) diag("schedule-uncertain", `keeping alive: ${sched.reason}`);
			return;
		}
		state.quiescentStreak += 1;
		if (state.quiescentStreak < timing.quiescentSamples) return;

		// Gate: create the stopping marker, then observe everything once more.
		deps.markers.create("stopping", new Date(now).toISOString());
		log(`quiescent for ${state.quiescentStreak} samples; stopping gate set, taking the final observation`);
		const finalLive = deps.leases().filter((l) => l.live);
		const finalSt = await probeStatus();
		const finalListRes = await deps.probes.list();
		const finalSchedRes = await deps.probes.schedule();
		const finalList = finalListRes.ok ? interpretList(finalListRes.json) : { ok: false, empty: false };
		const finalSched = finalSchedRes.ok ? interpretSchedule(finalSchedRes.json) : { ok: false, active: true };
		const finalQuiescent = finalLive.length === 0 && finalSt.ok && finalSt.defaultPresent && finalSt.quiescent && finalList.ok && finalList.empty && finalSched.ok && !finalSched.active;
		if (!finalQuiescent) {
			deps.markers.remove("stopping");
			state.quiescentStreak = 0;
			log("final observation no longer quiescent; stopping gate cleared");
			return;
		}
		log("final observation quiescent; shutting the empty supervisor down");
		const done = await finalShutdown();
		if (done.ok) {
			finish(EXIT_QUIESCENT, "automatic quiescence proven");
			return;
		}
		deps.markers.remove("stopping");
		state.quiescentStreak = 0;
		log(`automatic shutdown not clean (${done.reason}); gate cleared, recovering`);
	}

	async function terminate(signal) {
		if (state.phase === "exited" || state.phase === "terminating") return;
		state.phase = "terminating";
		log(`${signal} received: explicit stop, best-effort shutdown of every agent`);
		deps.markers.create("stopping", new Date(deps.now()).toISOString());
		const res = await deps.probes.shutdown();
		const sd = res.ok ? interpretShutdown(res.json) : { ok: false, reason: res.error ?? "shutdown probe failed" };
		if (!sd.ok) log(`shutdown reported problems: ${sd.reason}`);
		const deadline = deps.now() + timing.daemonExitWaitMs;
		while (state.daemon.child !== undefined && deps.now() <= deadline) await deps.sleep(250);
		if (state.daemon.child !== undefined) {
			log("daemon still running; sending SIGTERM");
			state.daemon.child.kill("SIGTERM");
			const killDeadline = deps.now() + 3_000;
			while (state.daemon.child !== undefined && deps.now() <= killDeadline) await deps.sleep(250);
			if (state.daemon.child !== undefined) state.daemon.child.kill("SIGKILL");
		}
		finish(EXIT_MANUAL_STOP, "explicit stop handled");
	}

	return { state, startup, step, terminate, noteDaemonExit };
}

// ---------------------------------------------------------------------------
// Real dependencies.
// ---------------------------------------------------------------------------

function realLog(message) {
	process.stdout.write(`[prime-agent-container] ${new Date().toISOString()} ${message}\n`);
}

function procStartTime(pid) {
	try {
		const parsed = parseProcStat(fs.readFileSync(`/proc/${pid}/stat`, "utf8"));
		if (!parsed || parsed.state === "Z" || parsed.state === "X") return undefined;
		return parsed.starttime;
	} catch {
		return undefined;
	}
}

function readLeases(runDir) {
	const clients = path.join(runDir, "clients");
	const leases = [];
	let names;
	try {
		names = fs.readdirSync(clients);
	} catch {
		return leases;
	}
	for (const name of names) {
		const dir = path.join(clients, name);
		if (name.startsWith(".")) {
			// An in-progress lease being renamed into place; drop it only if it is old.
			try {
				if (Date.now() - fs.lstatSync(dir).mtimeMs > 30_000) fs.rmSync(dir, { recursive: true, force: true });
			} catch {}
			continue;
		}
		const pid = Number.parseInt(name, 10);
		let starttime;
		try {
			if (!fs.lstatSync(dir).isDirectory()) throw new Error("not a directory");
			starttime = fs.readFileSync(path.join(dir, "starttime"), "utf8").trim();
		} catch {
			fs.rmSync(dir, { recursive: true, force: true });
			continue;
		}
		const live = Number.isInteger(pid) && pid > 0 && procStartTime(pid) === starttime;
		if (!live) {
			fs.rmSync(dir, { recursive: true, force: true });
			continue;
		}
		leases.push({ pid, starttime, live: true });
	}
	return leases;
}

function makeMarkers(runDir) {
	const file = (name) => path.join(runDir, name);
	return {
		create(name, content) {
			fs.writeFileSync(file(name), `${content}\n`, { mode: 0o600, flag: "w" });
		},
		remove(name) {
			fs.rmSync(file(name), { force: true });
		},
		exists(name) {
			return fs.existsSync(file(name));
		},
		readManual() {
			let text;
			try {
				text = fs.readFileSync(file("manual-shutdown"), "utf8");
			} catch {
				return undefined;
			}
			const [pidText, starttime] = text.trim().split(/\s+/);
			const pid = Number.parseInt(pidText ?? "", 10);
			if (!Number.isInteger(pid) || pid <= 0 || !starttime) {
				fs.rmSync(file("manual-shutdown"), { force: true });
				return undefined;
			}
			return { pid, starttime };
		},
	};
}

function makeProbes(cwd, env, timing) {
	const run = (args) =>
		new Promise((resolve) => {
			execFile(
				process.execPath,
				[BUNDLE, ...args],
				{ cwd, env, timeout: timing.probeTimeoutMs, killSignal: "SIGKILL", maxBuffer: 64 * 1024 * 1024, encoding: "utf8" },
				(error, stdout, stderr) => {
					if (error && (error.killed || error.signal)) {
						resolve({ ok: false, error: `${args.join(" ")} timed out after ${timing.probeTimeoutMs / 1000}s` });
						return;
					}
					const exitCode = error ? (typeof error.code === "number" ? error.code : 1) : 0;
					let json;
					try {
						json = JSON.parse(stdout.trim());
					} catch {
						resolve({
							ok: false,
							exitCode,
							error: `${args.join(" ")} exit ${exitCode}: ${(stderr || stdout).trim().split("\n").at(-1) ?? "no output"}`,
						});
						return;
					}
					resolve({ ok: true, exitCode, json });
				},
			);
		});
	return {
		status: () => run(["status", "--json"]),
		list: () => run(["list", "--json"]),
		schedule: () => run(["schedule", "list", "--all", "--json"]),
		shutdown: () => run(["shutdown", "--force", "--json"]),
	};
}

function checkTmpfs(dir, expectedMode) {
	const st = fs.lstatSync(dir);
	if (!st.isDirectory()) throw new Error(`${dir} is not a directory`);
	if (st.uid !== process.getuid()) throw new Error(`${dir} is owned by uid ${st.uid}, expected ${process.getuid()}`);
	if ((st.mode & 0o7777) !== expectedMode) throw new Error(`${dir} has mode ${(st.mode & 0o7777).toString(8)}, expected ${expectedMode.toString(8)}`);
	const parent = fs.statSync(path.dirname(dir));
	if (parent.dev === st.dev) throw new Error(`${dir} is not a mount point`);
	const fsInfo = fs.statfsSync(dir);
	if (fsInfo.type !== TMPFS_MAGIC) throw new Error(`${dir} is not tmpfs (f_type 0x${fsInfo.type.toString(16)})`);
}

function validateContract(runDir) {
	checkTmpfs(runDir, 0o700);
	checkTmpfs("/tmp", 0o1777);
	const entries = fs.readdirSync(runDir);
	if (entries.length > 0) throw new Error(`${runDir} is not empty (${entries.join(", ")}); the service must start in a fresh coordination tmpfs`);
	// The host launcher pins this to an empty value after any user env-file so a
	// project file cannot impersonate a client; only a non-empty value is a leak.
	if (process.env.PRIME_AGENT_CONTAINER_CLIENT) throw new Error("PRIME_AGENT_CONTAINER_CLIENT must not be set for the service");
	if (process.env.PRIME_AGENT_KERNEL_PYTHON !== undefined) throw new Error("PRIME_AGENT_KERNEL_PYTHON must not be set");
	if (!process.env.PRIME_AGENT_BUILD_ID) throw new Error("PRIME_AGENT_BUILD_ID is required");
	if (!fs.existsSync(BUNDLE)) throw new Error(`bundled CLI missing: ${BUNDLE}`);
	const agentDir = process.env.PRIME_AGENT_CODING_AGENT_DIR;
	if (!agentDir) throw new Error("PRIME_AGENT_CODING_AGENT_DIR is required");
	fs.mkdirSync(agentDir, { recursive: true });
	fs.accessSync(agentDir, fs.constants.W_OK);
	fs.mkdirSync(path.join(runDir, "clients"), { mode: 0o700 });
}

async function main() {
	const timing = DEFAULT_TIMING;
	try {
		validateContract(RUN_DIR);
	} catch (error) {
		realLog(`startup contract failure: ${error instanceof Error ? error.message : String(error)}`);
		process.exit(EXIT_STARTUP_FAILURE);
	}
	const version = JSON.parse(fs.readFileSync(PACKAGE_JSON, "utf8")).version;
	const env = { ...process.env };
	delete env.PRIME_AGENT_CONTAINER_CLIENT;
	const cwd = fs.existsSync("/work") ? "/work" : "/";
	const markers = makeMarkers(RUN_DIR);
	const controller = createController(
		{
			now: () => Date.now(),
			sleep: (ms) => sleep(ms),
			log: realLog,
			exit: (code) => process.exit(code),
			expected: { version, buildId: process.env.PRIME_AGENT_BUILD_ID },
			markers,
			leases: () => readLeases(RUN_DIR),
			processAlive: (pid, starttime) => procStartTime(pid) === starttime,
			probes: makeProbes(cwd, env, timing),
			daemon: {
				spawn(onExit) {
					const child = spawn(process.execPath, [BUNDLE, "--mode", "daemon"], { cwd, env, stdio: ["ignore", "inherit", "inherit"] });
					child.on("exit", (code, signal) => onExit(code, signal));
					child.on("error", (error) => {
						realLog(`daemon spawn error: ${error.message}`);
						onExit(null, null);
					});
					return { pid: child.pid, kill: (signal) => child.kill(signal) };
				},
			},
		},
		timing,
	);
	for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
		process.on(signal, () => void controller.terminate(signal));
	}
	if (!(await controller.startup())) return;
	while (controller.state.phase !== "exited") {
		try {
			await controller.step();
		} catch (error) {
			realLog(`monitor error: ${error instanceof Error ? (error.stack ?? error.message) : String(error)}`);
		}
		await sleep(timing.pollMs);
	}
}

// ---------------------------------------------------------------------------
// Self-test: fakes + virtual clock, no subprocesses, no filesystem.
// ---------------------------------------------------------------------------

async function selfTest() {
	const timing = { ...DEFAULT_TIMING, pollMs: 0 };
	let failures = 0;
	const results = [];
	const assert = (ok, message) => {
		results.push(`${ok ? "ok  " : "FAIL"} ${message}`);
		if (!ok) failures += 1;
	};

	function makeFake(overrides = {}) {
		const f = {
			clock: 1_000_000,
			logs: [],
			markers: new Map(),
			leases: [],
			alive: new Set(),
			status: [{ socketPath: "/tmp/prime-agent-0/daemon.sock", pid: 100, status: "current", isDefault: true, version: "0.9.1", buildId: "abc", sessionCount: 0 }],
			list: { sessions: [] },
			schedule: { jobs: [] },
			shutdownResult: { stopped: [{ socketPath: "s", action: "stopped" }], failed: [] },
			statusAfterShutdown: [],
			probeErrors: {},
			spawned: 0,
			exited: undefined,
			children: [],
			...overrides,
		};
		const probe = (kind, json) => async () => {
			if (f.probeErrors[kind]) return { ok: false, error: f.probeErrors[kind] };
			return { ok: true, exitCode: 0, json: typeof json === "function" ? json() : json };
		};
		const deps = {
			now: () => f.clock,
			sleep: async (ms) => {
				f.clock += ms;
			},
			log: (m) => f.logs.push(m),
			exit: (code) => {
				f.exited = code;
			},
			expected: { version: "0.9.1", buildId: "abc" },
			markers: {
				create: (n, c) => f.markers.set(n, c),
				remove: (n) => f.markers.delete(n),
				exists: (n) => f.markers.has(n),
				readManual: () => {
					const m = f.markers.get("manual-shutdown");
					if (!m) return undefined;
					const [p, s] = m.split(" ");
					return { pid: Number(p), starttime: s };
				},
			},
			leases: () => f.leases.filter((l) => l.live),
			processAlive: (pid, st) => f.alive.has(`${pid}:${st}`),
			probes: {
				status: probe("status", () => f.status),
				list: probe("list", () => f.list),
				schedule: probe("schedule", () => f.schedule),
				shutdown: async () => {
					if (f.probeErrors.shutdown) return { ok: false, error: f.probeErrors.shutdown };
					f.status = f.statusAfterShutdown;
					for (const c of f.children) c.exit(0, null);
					return { ok: true, exitCode: 0, json: f.shutdownResult };
				},
			},
			daemon: {
				spawn(onExit) {
					f.spawned += 1;
					const child = { pid: 100 + f.spawned, kill() {}, exit: (c, s) => onExit(c, s) };
					f.children.push(child);
					return child;
				},
			},
		};
		return { f, deps };
	}

	async function boot(overrides) {
		const { f, deps } = makeFake(overrides);
		const c = createController(deps, timing);
		await c.startup();
		return { f, deps, c };
	}
	const steps = async (c, f, n, dtMs = timing.pollMs || 5_000) => {
		for (let i = 0; i < n; i++) {
			await c.step();
			f.clock += dtMs;
		}
	};

	// 1. Startup publishes readiness only for one current default daemon.
	{
		const { f, c } = await boot();
		assert(c.state.phase === "running" && f.markers.has("ready"), "startup: ready marker after one current default daemon");
	}
	{
		const { f, c } = await boot({ status: [{ status: "stale", isDefault: true, version: "0.8.0", buildId: "x" }] });
		assert(c.state.phase === "exited" && f.exited === EXIT_STARTUP_FAILURE, "startup: foreign/stale default daemon → exit 70");
	}
	{
		const { f, c } = await boot({ status: [] });
		assert(f.exited === EXIT_STARTUP_FAILURE && f.logs.some((l) => l.includes("did not become ready")), "startup: no daemon within timeout → exit 70");
		void c;
	}

	// 2. First-client grace, then full gate, then exit 0.
	{
		const { f, c } = await boot();
		await steps(c, f, 3);
		assert(!f.markers.has("stopping") && f.exited === undefined, "grace: no stopping gate within the first-client grace");
		f.clock += timing.firstClientGraceMs;
		await steps(c, f, 2);
		assert(!f.markers.has("stopping"), "gate: two quiescent samples are not enough");
		await steps(c, f, 1);
		assert(f.exited === EXIT_QUIESCENT && f.markers.has("stopping") && f.status.length === 0, "gate: third sample → stopping marker → shutdown → status [] → exit 0");
		assert(f.logs.some((l) => l.includes("final observation quiescent")), "gate: final fresh observation logged");
	}

	// 3. Live lease keeps alive and arms; sessions keep alive after it ends.
	{
		const { f, c } = await boot();
		f.leases = [{ pid: 500, starttime: "77", live: true }];
		f.clock += timing.firstClientGraceMs + 1;
		await steps(c, f, 5);
		assert(c.state.armed && f.exited === undefined && !f.markers.has("stopping"), "lease: live client lease arms and pins the container");
		f.leases = [];
		f.list = { sessions: [{ id: "s1" }] };
		f.status[0].sessionCount = 1;
		await steps(c, f, 5);
		assert(f.exited === undefined, "lease gone but a visible session remains → keep alive");
		f.list = { sessions: [] };
		f.status[0].sessionCount = 0;
		await steps(c, f, 3);
		assert(f.exited === EXIT_QUIESCENT, "session passivated → three samples → exit 0");
	}

	// 4. Tracked workers with an empty list are not quiescent.
	{
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		f.status = [{ ...f.status[0], hasTrackedWorkers: true }];
		await steps(c, f, 5);
		assert(f.exited === undefined && c.state.armed && !f.markers.has("stopping"), "status: hasTrackedWorkers keeps alive even with list empty");
	}

	// 5. Schedules: active pins; paused/completed/cancelled do not; unknown status is uncertain.
	{
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		f.schedule = { jobs: [{ id: "j", status: "active", source: "heartbeat" }] };
		await steps(c, f, 5);
		assert(f.exited === undefined && c.state.armed, "schedule: active heartbeat job keeps alive");
		f.schedule = { jobs: [{ status: "paused" }, { status: "completed" }, { status: "cancelled" }] };
		await steps(c, f, 3);
		assert(f.exited === EXIT_QUIESCENT, "schedule: only paused/completed/cancelled jobs allow shutdown");
	}
	{
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		f.schedule = { jobs: [{ status: "sleeping" }] };
		await steps(c, f, 5);
		assert(f.exited === undefined, "schedule: unknown job status is uncertainty, keeps alive");
	}

	// 6. Malformed / failing probes never stop the container.
	for (const [kind, bad] of [
		["list", { nope: true }],
		["schedule", { jobs: "x" }],
		["status", { not: "array" }],
	]) {
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		if (kind === "list") f.list = bad;
		if (kind === "schedule") f.schedule = bad;
		if (kind === "status") f.status = bad;
		await steps(c, f, 5);
		assert(f.exited === undefined && !f.markers.has("stopping"), `malformed ${kind} --json keeps alive`);
	}
	for (const kind of ["list", "schedule", "status"]) {
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		f.probeErrors[kind] = `${kind} timed out`;
		await steps(c, f, 5);
		assert(f.exited === undefined && !f.markers.has("stopping"), `${kind} probe timeout/failure keeps alive`);
	}
	{
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		f.list = { sessions: [] };
		f.status[0].sessionCount = 2;
		await steps(c, f, 5);
		assert(f.exited === undefined, "list empty but status sessionCount>0 → probes disagree → keep alive");
	}

	// 7. Daemon crash loop: restart with backoff 1,2,5,30,30; never exit 0 because absent.
	{
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		f.status = [];
		const spawnsAt = [];
		const before = f.spawned;
		for (let i = 0; i < 400; i++) {
			// Every daemon the controller starts crashes immediately.
			for (const child of f.children) {
				if (!child.dead) {
					child.dead = true;
					child.exit(1, null);
				}
			}
			await c.step();
			if (f.spawned > spawnsAt.length + before) spawnsAt.push(f.clock);
			f.clock += 500;
		}
		const gaps = spawnsAt.slice(1).map((t, i) => (t - spawnsAt[i]) / 1000);
		assert(f.exited === undefined && f.spawned - before >= 5, `crash loop: ${f.spawned - before} restarts, no exit`);
		assert(gaps.length >= 4 && gaps.slice(0, 4).every((g, i) => Math.abs(g - [2, 5, 30, 30][i]) <= 1), `crash loop: backoff gaps ${gaps.slice(0, 4).join(",")}s (expected 2,5,30,30 after the first 1s)`);
	}
	{
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		f.status = [];
		const before = f.spawned;
		await steps(c, f, 20);
		assert(f.spawned === before && f.exited === undefined, "child alive but invisible to status → uncertain: no second daemon spawned, no exit");
	}

	// 7b. Dead daemon leaves an orphan socket file → restart; unreachable → wait; stale → never.
	{
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		f.children[0].exit(null, "SIGKILL");
		f.status = [{ socketPath: "/tmp/prime-agent-0/daemon.sock", status: "orphan-file", isDefault: true }];
		const before = f.spawned;
		await steps(c, f, 3, 1_000);
		assert(f.spawned === before + 1 && f.exited === undefined, "orphan-file default socket after a daemon crash → restart");
	}
	{
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		f.children[0].exit(0, null);
		f.status = [{ socketPath: "/tmp/prime-agent-0/daemon.sock", status: "unreachable", isDefault: true, pid: 4242 }];
		const before = f.spawned;
		await steps(c, f, 20);
		assert(f.spawned === before && f.exited === undefined && f.logs.some((l) => l.includes("unreachable")), "unreachable default socket → wait, no restart, no exit");
		f.status = [{ status: "current", isDefault: true, version: "0.9.1", buildId: "abc", pid: 4242, sessionCount: 0 }];
		await steps(c, f, 1);
		assert(c.state.daemon.adopted && c.state.daemon.pid === 4242, "unreachable socket that becomes current → adopted");
	}
	{
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		f.children[0].exit(0, null);
		f.status = [{ status: "stale", isDefault: true, version: "0.8.0", buildId: "old" }];
		const before = f.spawned;
		await steps(c, f, 20);
		assert(f.spawned === before && f.exited === undefined && f.logs.some((l) => l.includes("not restarting")), "stale default daemon → never restarted over, container kept alive");
	}

	// 8. Adoption of a worker-led replacement with the expected identity.
	{
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		f.children[0].exit(0, null);
		f.status = [{ status: "current", isDefault: true, version: "0.9.1", buildId: "abc", pid: 999, sessionCount: 1 }];
		const before = f.spawned;
		await steps(c, f, 3);
		assert(f.spawned === before && c.state.daemon.adopted && c.state.daemon.pid === 999, "replacement daemon with expected identity adopted, not respawned");
	}
	{
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		f.children[0].exit(0, null);
		f.status = [{ status: "current", isDefault: true, version: "0.9.1", buildId: "OTHER", pid: 999, sessionCount: 0 }];
		const before = f.spawned;
		await steps(c, f, 20);
		assert(f.spawned === before && !c.state.daemon.adopted && f.exited === undefined, "wrong-build default daemon: neither adopted nor restarted over, container kept alive");
	}

	// 9. Manual shutdown tied to the initiating client.
	{
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		f.markers.set("manual-shutdown", "600 55");
		f.alive.add("600:55");
		f.leases = [{ pid: 600, starttime: "55", live: true }];
		f.status = [];
		f.children[0].exit(0, null);
		const before = f.spawned;
		await steps(c, f, 5);
		assert(f.spawned === before && f.exited === undefined && f.markers.has("manual-shutdown"), "manual: marker with live initiating lease → wait, no restart");
		f.alive.clear();
		f.leases = [{ pid: 601, starttime: "56", live: true }];
		await steps(c, f, 3);
		assert(f.exited === undefined && c.state.manualHonored, "manual: initiator gone, daemon gone → honored, waiting for other clients");
		f.leases = [];
		await steps(c, f, 1);
		assert(f.exited === EXIT_MANUAL_STOP, "manual: last client gone → exit 75");
	}
	{
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		f.markers.set("manual-shutdown", "600 55");
		await steps(c, f, 1);
		assert(!f.markers.has("manual-shutdown") && f.exited === undefined, "manual: initiator gone but daemon reachable → marker cleared (cancelled shutdown)");
	}

	// 10. Gate race: a client that appears right after the stopping marker clears it.
	{
		const { f, deps } = makeFake();
		deps.leases = () => (f.markers.has("stopping") ? [{ pid: 700, starttime: "1", live: true }] : []);
		const c = createController(deps, timing);
		await c.startup();
		f.clock += timing.firstClientGraceMs + 1;
		await steps(c, f, 3);
		assert(!f.markers.has("stopping") && f.exited === undefined && c.state.quiescentStreak === 0, "race: lease created after the stopping marker → marker cleared, no shutdown");
	}

	// 11. Final shutdown failures clear the gate and keep the container alive.
	{
		const { f, c } = await boot({ shutdownResult: { stopped: [], failed: [{ socketPath: "s", reason: "worker unresponsive" }] } });
		f.clock += timing.firstClientGraceMs + 1;
		await steps(c, f, 3);
		assert(f.exited === undefined && !f.markers.has("stopping"), "shutdown reported failures → gate cleared, no exit 0");
	}
	{
		const { f, c } = await boot({ statusAfterShutdown: [{ status: "orphan-file", isDefault: true, socketPath: "x" }] });
		f.clock += timing.firstClientGraceMs + 1;
		await steps(c, f, 3);
		assert(f.exited === undefined && !f.markers.has("stopping"), "status does not converge to [] → gate cleared, no exit 0");
	}

	// 12. SIGTERM: explicit stop → shutdown → exit 75.
	{
		const { f, c } = await boot();
		f.leases = [{ pid: 1, starttime: "1", live: true }];
		await c.terminate("SIGTERM");
		assert(f.exited === EXIT_MANUAL_STOP && f.markers.has("stopping"), "SIGTERM → best-effort shutdown → exit 75 even with work present");
	}

	// 13. Diagnostics are rate-limited per key.
	{
		const { f, c } = await boot();
		f.clock += timing.firstClientGraceMs + 1;
		f.probeErrors.list = "list timed out";
		await steps(c, f, 20, 5_000);
		const n = f.logs.filter((l) => l.includes("keeping alive: list timed out")).length;
		assert(n >= 1 && n <= 3, `diagnostics: ${n} 'list timed out' line(s) over 100 s (rate-limited to ~1/min)`);
	}

	// 14. Pure interpreters.
	assert(interpretStatus([], { version: "v", buildId: "b" }).ok && interpretStatus([], { version: "v", buildId: "b" }).empty, "interpretStatus: [] is ok+empty (never quiescent by itself)");
	assert(!interpretStatus([{ status: "current", isDefault: true, version: "v", buildId: "b", sessionCount: undefined }], { version: "v", buildId: "b" }).quiescent, "interpretStatus: unknown sessionCount is not quiescent");
	assert(!interpretList({ sessions: "x" }).ok && interpretList({ sessions: [] }).empty, "interpretList shapes");
	assert(!interpretSchedule({ jobs: [{ status: 5 }] }).ok, "interpretSchedule: non-string status is uncertain");
	assert(interpretShutdown({ stopped: [], failed: [] }).ok && !interpretShutdown({ stopped: [], failed: [{}] }).ok, "interpretShutdown");
	// fields 4..21 are 18 numbers between the state and starttime (field 22)
	assert(parseProcStat("123 (a b) c) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 424242 21")?.starttime === "424242", "parseProcStat: comm with spaces and parens");
	{
		// The wrapper's shell pipeline and the controller's parser must agree on
		// the same live process: this node process.
		const self = parseProcStat(fs.readFileSync("/proc/self/stat", "utf8"));
		const { execFileSync } = await import("node:child_process");
		const viaShell = execFileSync("sh", ["-c", `sed 's/^.*) //' /proc/${process.pid}/stat | cut -d' ' -f20`], { encoding: "utf8" }).trim();
		assert(self !== undefined && /^\d+$/.test(self.starttime) && ["R", "S"].includes(self.state), `parseProcStat: real /proc/self/stat → state ${self?.state}, starttime ${self?.starttime}`);
		assert(viaShell === self?.starttime, `wrapper pipeline (sed|cut -f20) agrees with parseProcStat: ${viaShell}`);
	}

	for (const line of results) console.log(`  ${line}`);
	console.log(failures === 0 ? `\nself-test: ${results.length} checks passed` : `\nself-test: ${failures} of ${results.length} checks FAILED`);
	process.exit(failures === 0 ? 0 : 1);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	if (process.argv.includes("--self-test")) {
		await selfTest();
	} else {
		await main();
	}
}
