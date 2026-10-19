import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { createInterface } from "node:readline";
import { decodeFrame, type JsonObject, type RequestId, type ServerFrame } from "./protocol.js";

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
	/** Stop the child and every process it started. */
	kill(reason: Error): void;
	on(event: "request", listener: (frame: IncomingRequest) => void): this;
	on(event: "notification", listener: (frame: IncomingNotification) => void): this;
	on(event: "closed", listener: (error: Error) => void): this;
}

function firstLine(text: string): string {
	return text.split("\n", 1)[0].slice(0, 300);
}

export class CodexProtocolClient extends EventEmitter implements ProtocolClient {
	readonly #child: ChildProcessWithoutNullStreams;
	readonly #killGroup: boolean;
	#nextId = 0;
	#pending = new Map<RequestId, PendingRequest>();
	#closed = false;
	#killReason: Error | undefined;

	/** `killGroup` is true when the child leads its own process group. */
	constructor(child: ChildProcessWithoutNullStreams, killGroup: boolean) {
		super();
		this.#child = child;
		this.#killGroup = killGroup;
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

	kill(reason: Error): void {
		this.#killReason ??= reason;
		const child = this.#child;
		// The handle is ours until its exit event, so the pid still names it.
		if (child.exitCode === null && child.signalCode === null && child.pid !== undefined) {
			try {
				if (this.#killGroup) process.kill(-child.pid, "SIGKILL");
				else child.kill("SIGKILL");
			} catch {
				child.kill("SIGKILL");
			}
		}
		this.#close(reason);
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
				// A failed config/read can echo configuration text; name only the code.
				const detail = pending.decode === undefined && frame.message ? `\n${firstLine(frame.message)}` : "";
				pending.reject(new Error(`codex-request-failed method=${pending.method} code=${frame.code ?? "null"}${detail}`));
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
