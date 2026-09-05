/**
 * Container-owned test extension: a deterministic, credential-free model.
 *
 * Loaded into a Prime Agent session with `-e /path/to/faux-provider.js` and
 * selected with `--model faux/faux-1`. It runs inside the daemon *worker*
 * process (extensions always do) and registers a provider through the public
 * extension API (`pi.registerProvider` with a custom `streamSimple`, the same
 * path as upstream's `examples/extensions/custom-provider-anthropic`). It
 * answers every request in-process without any network.
 *
 * Why not `registerFauxProvider` from `@earendil-works/pi-ai`: extensions
 * resolve that package to `packages/ai/dist`, while the worker itself runs from
 * the esbuild bundle with its own copy of the API registry, so an API
 * registered from the extension is invisible to the bundle ("No API provider
 * registered for api: faux"). `streamSimple` on the provider config is the
 * supported bridge.
 *
 * Behavior per request:
 *   - appends one JSON line per model call to $PRIME_AGENT_FAUX_LOG
 *     (default /work/.faux/calls.jsonl) recording what the model actually saw:
 *     system-prompt length + sha256, whether it contains the container marker,
 *     tool names, the last user text; and writes the full system prompt to
 *     `prompt-<pid>-<n>.txt` next to it. This is the black-box observation
 *     channel for "the managed prompt/skills reached this session" (initial,
 *     resumed, recovered and recursive sessions alike);
 *   - `ack: <text>` for an ordinary user message;
 *   - a user message starting with `run-python:` produces one `ipython` tool
 *     call with the rest of the message as code; the follow-up request (tool
 *     result present) answers `done`. This is how tests drive `rlm(...)`,
 *     `bash(...)` and detached processes deterministically.
 *
 * Nothing here is part of the image; CI/acceptance mounts it read-only.
 */
import { createHash, randomUUID } from "node:crypto";
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";

const MARKER = process.env.PRIME_AGENT_FAUX_MARKER ?? "inside a Docker/Podman container";
const LOG = process.env.PRIME_AGENT_FAUX_LOG ?? "/work/.faux/calls.jsonl";
const USAGE = {
	input: 0,
	output: 0,
	cacheRead: 0,
	cacheWrite: 0,
	totalTokens: 0,
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};

let callCount = 0;

function textOf(content) {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.filter((block) => block && block.type === "text" && typeof block.text === "string")
		.map((block) => block.text)
		.join("\n");
}

function lastUserText(messages) {
	for (let i = messages.length - 1; i >= 0; i--) {
		const m = messages[i];
		if (m && m.role === "user") return textOf(m.content);
	}
	return "";
}

function lastMessageRole(messages) {
	const m = messages[messages.length - 1];
	return m ? m.role : undefined;
}

function record(entry, systemPrompt) {
	try {
		mkdirSync(dirname(LOG), { recursive: true });
		appendFileSync(LOG, `${JSON.stringify(entry)}\n`);
		writeFileSync(`${dirname(LOG)}/prompt-${process.pid}-${entry.call}.txt`, systemPrompt);
	} catch (error) {
		process.stderr.write(`faux-provider: cannot write ${LOG}: ${String(error)}\n`);
	}
}

/** Decide the reply for this request: text or one ipython tool call. */
function decide(context) {
	const messages = context.messages ?? [];
	const user = lastUserText(messages);
	if (lastMessageRole(messages) === "toolResult") {
		return { text: "done" };
	}
	// A subagent sees its task as "[task from parent] <prompt>", so match anywhere.
	const at = user.indexOf("run-python:");
	if (at >= 0) {
		return { toolCall: { type: "toolCall", id: `call_${randomUUID().slice(0, 12)}`, name: "ipython", arguments: { code: user.slice(at + "run-python:".length).trim() } } };
	}
	return { text: `ack: ${user}` };
}

function streamSimple(model, context, options) {
	const stream = createAssistantMessageEventStream();
	const messages = context.messages ?? [];
	const systemPrompt = context.systemPrompt ?? "";
	const call = ++callCount;
	record(
		{
			ts: new Date().toISOString(),
			pid: process.pid,
			call,
			model: model.id,
			cwd: process.cwd(),
			sessionId: options?.sessionId,
			systemPromptLength: systemPrompt.length,
			systemPromptSha256: createHash("sha256").update(systemPrompt).digest("hex"),
			hasContainerMarker: systemPrompt.includes(MARKER),
			tools: (context.tools ?? []).map((t) => t.name),
			messageCount: messages.length,
			lastRole: lastMessageRole(messages),
			lastUser: lastUserText(messages).slice(0, 200),
		},
		systemPrompt,
	);

	const reply = decide(context);
	const base = { role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id, usage: USAGE, stopReason: "stop", timestamp: Date.now() };
	queueMicrotask(() => {
		try {
			const partial = { ...base, content: [] };
			stream.push({ type: "start", partial: { ...partial } });
			if (reply.text !== undefined) {
				partial.content = [{ type: "text", text: "" }];
				stream.push({ type: "text_start", contentIndex: 0, partial: { ...partial } });
				partial.content = [{ type: "text", text: reply.text }];
				stream.push({ type: "text_delta", contentIndex: 0, delta: reply.text, partial: { ...partial } });
				stream.push({ type: "text_end", contentIndex: 0, content: reply.text, partial: { ...partial } });
				const message = { ...partial, stopReason: "stop" };
				stream.push({ type: "done", reason: "stop", message });
				stream.end(message);
			} else {
				partial.content = [reply.toolCall];
				stream.push({ type: "toolcall_start", contentIndex: 0, partial: { ...partial } });
				stream.push({ type: "toolcall_delta", contentIndex: 0, delta: JSON.stringify(reply.toolCall.arguments), partial: { ...partial } });
				stream.push({ type: "toolcall_end", contentIndex: 0, toolCall: reply.toolCall, partial: { ...partial } });
				const message = { ...partial, stopReason: "toolUse" };
				stream.push({ type: "done", reason: "toolUse", message });
				stream.end(message);
			}
		} catch (error) {
			const message = { ...base, stopReason: "error", errorMessage: String(error) };
			stream.push({ type: "error", reason: "error", error: message });
			stream.end(message);
		}
	});
	return stream;
}

export default function fauxProviderExtension(pi) {
	pi.registerProvider("faux", {
		name: "Faux (container test)",
		api: "faux",
		baseUrl: "http://localhost:0",
		apiKey: "faux-no-key",
		streamSimple,
		models: [
			{
				id: "faux-1",
				name: "Faux 1",
				reasoning: false,
				input: ["text"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 128000,
				maxTokens: 16384,
			},
		],
	});
}
