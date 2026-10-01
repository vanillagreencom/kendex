import { EventEmitter } from "node:events";

class Request extends EventEmitter {
	destroyedCount = 0;
	end() {}
	destroy() { this.destroyedCount++; }
}
class Response extends EventEmitter {
	statusCode: number;
	destroyedCount = 0;
	constructor(statusCode: number) { super(); this.statusCode = statusCode; }
	destroy() { this.destroyedCount++; }
}
let current: { req: Request; respond: (res: Response) => void };

export function request(_options: unknown, respond: (res: Response) => void): Request {
	const req = new Request();
	current = { req, respond };
	return req;
}
export function pendingRequest(): Request { return current.req; }
export function respond(statusCode = 200): Response {
	const res = new Response(statusCode);
	current.respond(res);
	return res;
}
