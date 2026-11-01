import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { createInterface } from "node:readline";
import { descendantsOf, killSurvivors } from "./process-tree.js";
import { classifyRequestFailure, decodeFrame, type JsonObject, type RequestFailureKind, type RequestId, type ServerFrame } from "./protocol.js";

/** How long Codex has to stop itself and its MCP servers after SIGTERM. */
export const TERMINATE_GRACE_MS = 3000;

/** A JSON-RPC error reply, keyed by method and code. `kind` names a cause the
 * bridge acts on; Codex's own text is never part of the message. */
export class CodexRequestError extends Error {
	readonly method: string;
	readonly code: number | null;
	readonly kind: RequestFailureKind | null;

	constructor(method: string, code: number | null, kind: RequestFailureKind | null) {
		super(`codex-request-failed method=${method} code=${code ?? "null"}${kind === null ? "" : ` cause=${kind}`}`);
		this.method = method;
		this.code = code;
		this.kind = kind;
	}
}

type PendingRequest = {
	method: string;
	decode?: (result: unknown) => unknown;
	resolve(value: unknown): void;
	reject(error: Error): void;
};

export type IncomingRequest = Extract<ServerFrame, { kind: "request" }>;
export type IncomingNotification = Extract<ServerFrame, { kind: "notification" }>;

/** What the bridge needs from a connection to one app-server child. */
export interface ProtocolClient {
	request(method: string, params: JsonObject): Promise<unknown>;
	/** A request whose result `decode` narrows inside the parse of its response line. */
	requestDecoded<T>(method: string, params: JsonObject, decode: (result: unknown) => T): Promise<T>;
	notify(method: string, params?: JsonObject): void;
	respond(id: RequestId, result: unknown): void;
	respondError(id: RequestId, code: number, message: string): void;
	/**
	 * Fail every request with `reason`, then stop the child. Codex gets stdin
	 * EOF and SIGTERM to its process group, and its own teardown stops the MCP
	 * servers it started in their own groups. A child still running after the
	 * grace gets SIGKILL. Once it has exited, each process recorded below it
	 * before the first signal that still runs gets SIGKILL, with its group when
	 * it leads one. Resolves after that. On Windows only the child is signalled.
	 */
	kill(reason: Error): Promise<void>;
	on(event: "request", listener: (frame: IncomingRequest) => void): this;
	on(event: "notification", listener: (frame: IncomingNotification) => void): this;
	on(event: "closed", listener: (error: Error) => void): this;
}

export class CodexProtocolClient extends EventEmitter implements ProtocolClient {
	readonly #child: ChildProcessWithoutNullStreams;
	readonly #killGroup: boolean;
	readonly #graceMs: number;
	#nextId = 0;
	#pending = new Map<RequestId, PendingRequest>();
	#closed = false;
	#killReason: Error | undefined;
	#termination: Promise<void> | undefined;

	/** `killGroup` is true when the child leads its own process group. */
	constructor(child: ChildProcessWithoutNullStreams, killGroup: boolean, graceMs = TERMINATE_GRACE_MS) {
		super();
		this.#child = child;
		this.#killGroup = killGroup;
		this.#graceMs = graceMs;
		const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
		lines.on("line", (line) => this.#receive(line));
		// Codex logs to stderr; the bridge neither reads nor forwards it.
		child.stderr.resume();
		child.stdin.on("error", () => undefined);
		child.once("error", (error: NodeJS.ErrnoException) => {
			this.#close(new Error(`codex-spawn-failed code=${error.code ?? "unknown"}`));
		});
		child.once("exit", (code, signal) => {
			this.#close(this.#killReason ?? new Error(`codex-app-server-exit code=${code ?? "null"} signal=${signal ?? "null"}`));
		});
	}

	request(method: string, params: JsonObject): Promise<unknown> {
		return this.#send(method, params, undefined);
	}

	requestDecoded<T>(method: string, params: JsonObject, decode: (result: unknown) => T): Promise<T> {
		return this.#send(method, params, decode) as Promise<T>;
	}

	notify(method: string, params?: JsonObject): void {
		this.#write(params === undefined ? { method } : { method, params });
	}

	respond(id: RequestId, result: unknown): void {
		this.#write({ id, result });
	}

	respondError(id: RequestId, code: number, message: string): void {
		this.#write({ id, error: { code, message } });
	}

	kill(reason: Error): Promise<void> {
		this.#killReason ??= reason;
		this.#close(reason);
		this.#termination ??= this.#terminate();
		return this.#termination;
	}

	async #terminate(): Promise<void> {
		const child = this.#child;
		const exited = new Promise<void>((resolve) => {
			if (child.exitCode !== null || child.signalCode !== null) resolve();
			else child.once("exit", () => resolve());
		});
		// The handle is ours until its exit event, so the pid still names it.
		if (child.exitCode !== null || child.signalCode !== null || child.pid === undefined) return;
		const pid = child.pid;
		const below = this.#killGroup ? descendantsOf(pid) : [];
		const signal = (name: NodeJS.Signals) => {
			if (child.exitCode !== null || child.signalCode !== null) return;
			try {
				if (this.#killGroup) process.kill(-pid, name);
				else child.kill(name);
			} catch {
				child.kill(name);
			}
		};
		child.stdin.end();
		signal("SIGTERM");
		let timer: NodeJS.Timeout | undefined;
		const graceful = await Promise.race([
			exited.then(() => true),
			new Promise<boolean>((resolve) => (timer = setTimeout(() => resolve(false), this.#graceMs))),
		]);
		clearTimeout(timer);
		if (!graceful) {
			signal("SIGKILL");
			await exited;
		}
		// Codex's teardown stops the MCP servers it started in their own
		// process groups. A process recorded below the child that still runs,
		// because the child was SIGKILLed or ignored its teardown, stops here.
		killSurvivors(below);
	}

	#send(method: string, params: JsonObject, decode: ((result: unknown) => unknown) | undefined): Promise<unknown> {
		if (this.#closed) return Promise.reject(this.#killReason ?? new Error("codex-app-server-closed"));
		const id = this.#nextId++;
		return new Promise((resolve, reject) => {
			this.#pending.set(id, { method, decode, resolve, reject });
			this.#write({ method, id, params });
		});
	}

	#write(message: unknown): void {
		if (this.#closed) return;
		this.#child.stdin.write(`${JSON.stringify(message)}\n`);
	}

	#decodeResult(id: RequestId, result: unknown): unknown {
		const decode = this.#pending.get(id)?.decode;
		if (decode === undefined) return result;
		try {
			return { decoded: decode(result) };
		} catch (error) {
			return { failed: error instanceof Error ? error : new Error("codex-protocol-decode-failed") };
		}
	}

	#receive(line: string): void {
		if (this.#closed) return;
		let frame: ServerFrame;
		try {
			frame = JSON.parse(line, (key, value) => key === "" ? decodeFrame(value, (id, result) => this.#decodeResult(id, result)) : value) as ServerFrame;
		} catch (error) {
			// The line itself is never quoted: a config/read reply carries values.
			this.kill(new Error(error instanceof SyntaxError ? "codex-protocol-invalid-json" : (error as Error).message));
			return;
		}
		if (frame.kind === "response" || frame.kind === "error") {
			const pending = this.#pending.get(frame.id);
			if (!pending) return;
			this.#pending.delete(frame.id);
			if (frame.kind === "error") {
				// Codex's error text can quote configuration lines, so it is
				// classified here and never passed on.
				pending.reject(new CodexRequestError(pending.method, frame.code, classifyRequestFailure(pending.method, frame.code, frame.message)));
				return;
			}
			if (pending.decode === undefined) {
				pending.resolve(frame.result);
				return;
			}
			const outcome = frame.result as { decoded?: unknown; failed?: Error };
			if (outcome.failed) pending.reject(outcome.failed);
			else pending.resolve(outcome.decoded);
			return;
		}
		this.emit(frame.kind, frame);
	}

	#close(error: Error): void {
		if (this.#closed) return;
		this.#closed = true;
		for (const pending of this.#pending.values()) pending.reject(error);
		this.#pending.clear();
		this.emit("closed", error);
	}
}
