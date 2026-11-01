// A scripted Responses API on 127.0.0.1 that Codex uses as a model provider,
// so a real app-server runs whole turns with no login and no network.
import { createServer } from "node:http";

/** `script` holds one list of output items per model request, in order. */
export async function startMockResponses(script) {
	const requests = [];
	const server = createServer((req, res) => {
		let body = "";
		req.on("data", (chunk) => (body += chunk));
		req.on("end", () => {
			let parsed = null;
			try {
				parsed = JSON.parse(body);
			} catch {
				// A non-JSON body is recorded as null; the test reads what it needs.
			}
			requests.push({ url: req.url, body: parsed });
			if (req.method !== "POST" || !req.url.endsWith("/responses")) {
				res.writeHead(404);
				res.end();
				return;
			}
			const items = script.shift() ?? [message("end")];
			const id = `resp_${requests.length}`;
			res.writeHead(200, { "content-type": "text/event-stream" });
			const send = (event) => res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
			send({ type: "response.created", response: { id } });
			for (const item of items) send({ type: "response.output_item.done", item });
			send({ type: "response.completed", response: { id, usage: { input_tokens: 5, input_tokens_details: null, output_tokens: 3, output_tokens_details: null, total_tokens: 8 } } });
			res.end();
		});
	});
	await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
	return {
		requests,
		port: server.address().port,
		// A response still open, as for a stalled row, would hold close forever.
		close: () => new Promise((resolve) => {
			server.close(resolve);
			server.closeAllConnections();
		}),
	};
}

export function message(text, id = `msg_${text.length}_${Date.now()}`) {
	return { type: "message", role: "assistant", id, content: [{ type: "output_text", text }] };
}

/** A function call; `namespace` names the tool namespace it calls into. */
export function functionCall(name, args, callId, namespace) {
	return { type: "function_call", call_id: callId, name, arguments: JSON.stringify(args), ...(namespace === undefined ? {} : { namespace }) };
}

/** Every tool name offered to the model in one request, nested ones included. */
export function offeredTools(body) {
	const names = [];
	const walk = (tools, prefix) => {
		for (const tool of tools ?? []) {
			const name = tool.name ?? tool.type;
			names.push(prefix + name);
			if (Array.isArray(tool.tools)) walk(tool.tools, `${prefix}${name}.`);
		}
	};
	walk(body?.tools, "");
	for (const item of body?.input ?? []) if (item.type === "additional_tools") walk(item.tools, "");
	return names;
}
