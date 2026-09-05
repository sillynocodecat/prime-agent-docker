/**
 * Print the daemon's agent roster as JSON — what the Agents View shows.
 *
 * Runs inside the container (`node /ci/roster.mjs`) against the default daemon
 * socket, using the same `roster_subscribe` request the Agents View issues, and
 * prints one JSON object: `{ roster: [{ agentId, lifecycle, activity, status,
 * statusLabel, workerId, sessionFile, attachedClients, sessionName }] }`.
 * Test-only; it never ships in the image.
 */
import { DaemonClient } from "/opt/prime-agent/packages/coding-agent/dist/modes/daemon/daemon-client.js";
import { defaultDaemonSocketPath } from "/opt/prime-agent/packages/coding-agent/dist/modes/daemon/daemon-socket.js";

const client = new DaemonClient(process.env.PRIME_AGENT_DAEMON_SOCKET ?? defaultDaemonSocketPath());
await client.connect();
try {
	const response = await client.request({ type: "roster_subscribe" });
	if (!response.success) throw new Error(response.error ?? "roster_subscribe failed");
	const roster = (response.roster ?? []).map((entry) => ({
		agentId: entry.agentId,
		lifecycle: entry.summary?.lifecycle,
		activity: entry.summary?.activity,
		status: entry.status,
		statusLabel: entry.statusLabel,
		workerId: entry.workerId,
		sessionFile: entry.summary?.sessionFile,
		sessionName: entry.summary?.sessionName,
		attachedClients: entry.summary?.attachedClients,
		messageCount: entry.summary?.messageCount,
		hasRegisteredCronJob: entry.summary?.hasRegisteredCronJob,
		hasActiveHeartbeat: entry.summary?.hasActiveHeartbeat,
	}));
	await client.request({ type: "roster_unsubscribe" });
	process.stdout.write(`${JSON.stringify({ roster })}\n`);
} finally {
	client.close();
}
