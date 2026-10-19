import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { createInterface } from "node:readline";
import type { JsonObject, RequestId, ServerMessage } from "./protocol.js";

type PendingRequest = {
	resolve(value: unknown): void;
	reject(error: Error): void;
};

export class CodexProtocolClient extends EventEmitter {
	readonly child: ChildProcessWithoutNullStreams;
	#nextId = 0;
	#pending = new Map<RequestId, PendingRequest>();
	#closed = false;

	constructor(child: ChildProcessWithoutNullStreams) {
		super();
		this.child = child;
		const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
		lines.on("line", (line) => this.#receive(line));
		child.stderr.resume();
		child.once("error", (error) => this.#close(error));
		child.once("exit", (code, signal) => {
			this.#close(new Error(`codex-app-server-exit code=${code ?? "null"} signal=${signal ?? "null"}`));
		});
	}

	request(method: string, params: JsonObject = {}): Promise<unknown> {
		if (this.#closed) return Promise.reject(new Error("codex-app-server-closed"));
		const id = this.#nextId++;
		return new Promise((resolve, reject) => {
			this.#pending.set(id, { resolve, reject });
			this.#write({ method, id, params });
		});
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

	close(): void {
		if (!this.#closed) this.child.kill();
	}

	#write(message: ServerMessage): void {
		if (this.#closed) throw new Error("codex-app-server-closed");
		this.child.stdin.write(`${JSON.stringify(message)}\n`);
	}

	#receive(line: string): void {
		let message: ServerMessage;
		try {
			message = JSON.parse(line) as ServerMessage;
		} catch {
			this.child.kill();
			this.#close(new Error("codex-protocol-invalid-json"));
			return;
		}
		if (message.id !== undefined && message.method === undefined) {
			const pending = this.#pending.get(message.id);
			if (!pending) return;
			this.#pending.delete(message.id);
			if (message.error !== undefined) pending.reject(new Error("codex-protocol-request-failed"));
			else pending.resolve(message.result);
			return;
		}
		if (message.method !== undefined && message.id !== undefined) {
			this.emit("request", message);
			return;
		}
		if (message.method !== undefined) this.emit("notification", message);
	}

	#close(error: Error): void {
		if (this.#closed) return;
		this.#closed = true;
		for (const pending of this.#pending.values()) pending.reject(error);
		this.#pending.clear();
		this.emit("closed", error);
	}
}
