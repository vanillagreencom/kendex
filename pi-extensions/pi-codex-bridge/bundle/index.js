// src/index.ts
import * as piAi from "@earendil-works/pi-ai";

// src/app-server.ts
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";

// src/codex-environment.ts
var CREDENTIAL_NAME = /(?:AUTH|CREDENTIAL|PASSWORD|PASSWD|PRIVATE_KEY|ACCESS_KEY|API_KEY|SECRET|TOKEN)/i;
function codexChildEnvironment(codexHome, env = process.env) {
  const child = {};
  for (const [name, value] of Object.entries(env)) {
    if (name !== "CODEX_HOME" && CREDENTIAL_NAME.test(name)) continue;
    child[name] = value;
  }
  child.CODEX_HOME = codexHome;
  return child;
}

// src/json-rpc.ts
import { EventEmitter } from "node:events";
import { createInterface } from "node:readline";
var CodexProtocolClient = class extends EventEmitter {
  child;
  #nextId = 0;
  #pending = /* @__PURE__ */ new Map();
  #closed = false;
  constructor(child) {
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
  request(method, params = {}) {
    if (this.#closed) return Promise.reject(new Error("codex-app-server-closed"));
    const id = this.#nextId++;
    return new Promise((resolve2, reject) => {
      this.#pending.set(id, { resolve: resolve2, reject });
      this.#write({ method, id, params });
    });
  }
  notify(method, params) {
    this.#write(params === void 0 ? { method } : { method, params });
  }
  respond(id, result) {
    this.#write({ id, result });
  }
  respondError(id, code, message) {
    this.#write({ id, error: { code, message } });
  }
  close() {
    if (!this.#closed) this.child.kill();
  }
  #write(message) {
    if (this.#closed) throw new Error("codex-app-server-closed");
    this.child.stdin.write(`${JSON.stringify(message)}
`);
  }
  #receive(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      this.child.kill();
      this.#close(new Error("codex-protocol-invalid-json"));
      return;
    }
    if (message.id !== void 0 && message.method === void 0) {
      const pending = this.#pending.get(message.id);
      if (!pending) return;
      this.#pending.delete(message.id);
      if (message.error !== void 0) pending.reject(new Error("codex-protocol-request-failed"));
      else pending.resolve(message.result);
      return;
    }
    if (message.method !== void 0 && message.id !== void 0) {
      this.emit("request", message);
      return;
    }
    if (message.method !== void 0) this.emit("notification", message);
  }
  #close(error) {
    if (this.#closed) return;
    this.#closed = true;
    for (const pending of this.#pending.values()) pending.reject(error);
    this.#pending.clear();
    this.emit("closed", error);
  }
};

// src/protocol.ts
var INITIALIZE_PARAMS = {
  clientInfo: {
    name: "pi_codex_bridge",
    title: "Pi Codex bridge",
    version: "1.0.0"
  },
  capabilities: {
    experimentalApi: true,
    requestAttestation: false
  }
};

// src/app-server.ts
var execFileAsync = promisify(execFile);
var SUPPORTED_CODEX_VERSION = "0.154.0";
var APP_SERVER_ARGS = [
  "app-server",
  "--stdio",
  "--disable",
  "shell_tool",
  "--disable",
  "apps",
  "--disable",
  "plugins",
  "--disable",
  "remote_plugin",
  "--disable",
  "multi_agent",
  "--disable",
  "browser_use",
  "--disable",
  "computer_use",
  "--disable",
  "image_generation",
  "--disable",
  "view_image",
  "--disable",
  "sleep_tool",
  "--disable",
  "hooks",
  "-c",
  'web_search="disabled"'
];
function object(value, key) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`codex-protocol-invalid-${key}`);
  }
  return value;
}
async function assertSupportedCodex(executable, codexHome, env = process.env) {
  const childEnv = codexChildEnvironment(codexHome, env);
  const { stdout } = await execFileAsync(executable, ["--version"], {
    env: childEnv,
    encoding: "utf8",
    maxBuffer: 4096
  });
  if (stdout.trim() !== `codex-cli ${SUPPORTED_CODEX_VERSION}`) {
    throw new Error(`codex-version-unsupported expected=${SUPPORTED_CODEX_VERSION}`);
  }
}
async function startAppServer(executable, codexHome, env = process.env) {
  await assertSupportedCodex(executable, codexHome, env);
  const child = spawn(executable, [...APP_SERVER_ARGS], {
    env: codexChildEnvironment(codexHome, env),
    stdio: ["pipe", "pipe", "pipe"]
  });
  const client = new CodexProtocolClient(child);
  await client.request("initialize", INITIALIZE_PARAMS);
  client.notify("initialized");
  return client;
}
async function listCodexModels(client) {
  const models = [];
  let cursor = null;
  do {
    const response = object(await client.request("model/list", {
      includeHidden: false,
      ...cursor === null ? {} : { cursor }
    }), "model-list");
    if (!Array.isArray(response.data)) throw new Error("codex-protocol-invalid-model-list-data");
    for (const raw of response.data) {
      const model = object(raw, "model");
      const reasoningEfforts = Array.isArray(model.supportedReasoningEfforts) ? model.supportedReasoningEfforts : [];
      if (typeof model.id !== "string" || typeof model.model !== "string" || typeof model.displayName !== "string" || typeof model.description !== "string" || typeof model.hidden !== "boolean" || !Array.isArray(model.inputModalities) || !Array.isArray(model.supportedReasoningEfforts) || reasoningEfforts.some((entry) => {
        const effort = object(entry, "model-reasoning-effort");
        return typeof effort.reasoningEffort !== "string" || typeof effort.description !== "string";
      }) || typeof model.defaultReasoningEffort !== "string" || typeof model.isDefault !== "boolean") throw new Error("codex-protocol-invalid-model");
      models.push(model);
    }
    if (response.nextCursor !== null && typeof response.nextCursor !== "string") {
      throw new Error("codex-protocol-invalid-model-cursor");
    }
    cursor = response.nextCursor;
  } while (cursor !== null);
  return models;
}

// src/auth-presence.ts
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
var LOGIN_MISSING_KEY = "codex-login-missing";
function resolveCodexHome(env = process.env, userHome = homedir()) {
  const configured = env.CODEX_HOME;
  if (typeof configured === "string" && configured.trim().length > 0) return configured;
  return join(userHome, ".codex");
}
function hasCodexLogin(codexHome) {
  return existsSync(join(codexHome, "auth.json"));
}
function loginMissingMessage(codexHome) {
  return `${LOGIN_MISSING_KEY} home=${codexHome}`;
}
function requireCodexLogin(codexHome) {
  if (!hasCodexLogin(codexHome)) throw new Error(loginMissingMessage(codexHome));
}

// src/bridge.ts
import {
  collapseSystemMessages,
  createAssistantMessageEventStream,
  getCurrentSystemPrompt,
  getCurrentTools
} from "@earendil-works/pi-ai";

// src/dynamic-tools.ts
var TOOL_NAME_LIMIT = 64;
function baseName(name) {
  const normalized = name.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, TOOL_NAME_LIMIT);
  return normalized.length > 0 ? normalized : "pi_tool";
}
function buildDynamicTools(tools) {
  const declarations = [];
  const piNameByCodexName = /* @__PURE__ */ new Map();
  for (const tool of tools) {
    const stem = baseName(tool.name);
    let name = stem;
    let suffix = 2;
    while (piNameByCodexName.has(name)) {
      const tail = `_${suffix++}`;
      name = `${stem.slice(0, TOOL_NAME_LIMIT - tail.length)}${tail}`;
    }
    piNameByCodexName.set(name, tool.name);
    declarations.push({
      type: "function",
      name,
      description: tool.description,
      inputSchema: tool.parameters
    });
  }
  return {
    declarations,
    piNameByCodexName,
    signature: JSON.stringify(declarations)
  };
}

// src/tool-pairing.ts
function toolResultText(result) {
  const parts = [];
  for (const item of result.content) {
    if (item.type === "text") parts.push(item.text);
    else if (item.type === "image") parts.push(`[image ${item.mimeType}]`);
  }
  return parts.join("\n");
}
function deliverToolResults(client, pending, results) {
  const seen = /* @__PURE__ */ new Set();
  for (const result of results) {
    if (seen.has(result.toolCallId)) throw new Error(`codex-tool-result-duplicate call=${result.toolCallId}`);
    seen.add(result.toolCallId);
    const call = pending.get(result.toolCallId);
    if (!call) throw new Error(`codex-tool-result-unmatched call=${result.toolCallId}`);
    if (call.piToolName !== result.toolName) {
      throw new Error(`codex-tool-result-name-mismatch call=${result.toolCallId}`);
    }
  }
  if (seen.size !== pending.size) {
    throw new Error(`codex-tool-result-missing count=${pending.size - seen.size}`);
  }
  for (const result of results) {
    const call = pending.get(result.toolCallId);
    if (!call) throw new Error(`codex-tool-result-unmatched call=${result.toolCallId}`);
    client.respond(call.requestId, {
      contentItems: [{ type: "inputText", text: toolResultText(result) }],
      success: !result.isError
    });
    pending.delete(result.toolCallId);
  }
}

// src/bridge.ts
var PROVIDER_ID = "pi-codex";
var API_ID = "codex-app-server";
function asObject(value, key) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`codex-protocol-invalid-${key}`);
  }
  return value;
}
function emptyUsage() {
  return {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
  };
}
function outputMessage(model, threadId) {
  return {
    role: "assistant",
    content: [],
    api: API_ID,
    provider: PROVIDER_ID,
    model: model.id,
    responseId: threadId,
    usage: emptyUsage(),
    stopReason: "pending",
    timestamp: Date.now()
  };
}
function textInput(content) {
  if (typeof content === "string") return [{ type: "text", text: content, text_elements: [] }];
  return content.map((item) => {
    if (item.type === "text") return { type: "text", text: item.text, text_elements: [] };
    return { type: "image", url: `data:${item.mimeType};base64,${item.data}` };
  });
}
function serializedHistory(messages) {
  return messages.filter((message) => message.role !== "system").map((message) => {
    if (message.role === "user") {
      const text = typeof message.content === "string" ? message.content : message.content.filter((item) => item.type === "text").map((item) => item.text).join("\n");
      return `User:
${text}`;
    }
    if (message.role === "assistant") {
      const text = message.content.filter((item) => item.type === "text").map((item) => item.text).join("\n");
      return `Assistant:
${text}`;
    }
    return `Tool ${message.toolName}:
${message.content.filter((item) => item.type === "text").map((item) => item.text).join("\n")}`;
  }).join("\n\n");
}
function latestThreadId(messages) {
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index];
    if (message.role === "assistant" && message.provider === PROVIDER_ID && message.responseId) {
      return message.responseId;
    }
  }
  return void 0;
}
function inputAfterThreadMessage(messages, threadId) {
  if (threadId === void 0) {
    return [{ type: "text", text: serializedHistory(messages), text_elements: [] }];
  }
  let boundary = -1;
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index];
    if (message.role === "assistant" && message.responseId === threadId) {
      boundary = index;
      break;
    }
  }
  return messages.slice(boundary + 1).flatMap((message) => message.role === "user" ? textInput(message.content) : []);
}
function toolResultsAfterThreadMessage(messages, threadId) {
  let boundary = -1;
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index];
    if (message.role === "assistant" && message.responseId === threadId) {
      boundary = index;
      break;
    }
  }
  return messages.slice(boundary + 1).filter((message) => message.role === "toolResult");
}
function responseThread(value) {
  const result = asObject(value, "thread-response");
  const thread = asObject(result.thread, "thread");
  if (typeof thread.id !== "string") throw new Error("codex-protocol-invalid-thread-id");
  return { thread: { id: thread.id } };
}
function responseTurn(value) {
  const result = asObject(value, "turn-response");
  const turn = asObject(result.turn, "turn");
  if (typeof turn.id !== "string") throw new Error("codex-protocol-invalid-turn-id");
  return { turn: { id: turn.id } };
}
function dynamicToolCall(message) {
  const params = asObject(message.params, "dynamic-tool-call");
  if (typeof params.threadId !== "string" || typeof params.turnId !== "string" || typeof params.callId !== "string" || params.namespace !== null && typeof params.namespace !== "string" || typeof params.tool !== "string") throw new Error("codex-protocol-invalid-dynamic-tool-call");
  return {
    threadId: params.threadId,
    turnId: params.turnId,
    callId: params.callId,
    namespace: params.namespace,
    tool: params.tool,
    arguments: asObject(params.arguments, "dynamic-tool-arguments")
  };
}
function updateUsage(output, params) {
  const tokenUsage = asObject(params.tokenUsage, "token-usage");
  const last = asObject(tokenUsage.last, "token-usage-last");
  const input = typeof last.inputTokens === "number" ? last.inputTokens : 0;
  const outputTokens = typeof last.outputTokens === "number" ? last.outputTokens : 0;
  const cacheRead = typeof last.cachedInputTokens === "number" ? last.cachedInputTokens : 0;
  const cacheWrite = typeof last.cacheWriteInputTokens === "number" ? last.cacheWriteInputTokens : 0;
  output.usage = {
    input,
    output: outputTokens,
    cacheRead,
    cacheWrite,
    totalTokens: typeof last.totalTokens === "number" ? last.totalTokens : input + outputTokens,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
  };
}
var CodexBridge = class {
  executable;
  codexHome;
  cwd;
  env;
  startClient;
  #sessions = /* @__PURE__ */ new Map();
  constructor(options) {
    this.executable = options.executable ?? "codex";
    this.codexHome = options.codexHome;
    this.cwd = options.cwd ?? process.cwd();
    this.env = options.env ?? process.env;
    this.startClient = options.startClient ?? startAppServer;
  }
  streamSimple = (model, context, options) => {
    const stream = createAssistantMessageEventStream();
    void this.#run(stream, model, context, options);
    return stream;
  };
  async close() {
    for (const session of this.#sessions.values()) session.client.close();
    this.#sessions.clear();
  }
  async #session(model, threadId, tools, systemPrompt) {
    const existing = threadId === void 0 ? void 0 : this.#sessions.get(threadId);
    if (existing) {
      if (existing.modelId !== model.id) throw new Error("codex-model-changed-start-new-session");
      if (existing.toolSignature !== tools.signature) throw new Error("codex-tool-set-changed-start-new-session");
      return existing;
    }
    const client = await this.startClient(this.executable, this.codexHome, this.env);
    if (threadId !== void 0) {
      const resumed = responseThread(await client.request("thread/resume", {
        threadId,
        model: model.id,
        cwd: this.cwd,
        approvalPolicy: "never",
        sandbox: "read-only"
      }));
      const session2 = {
        client,
        threadId: resumed.thread.id,
        modelId: model.id,
        toolSignature: tools.signature,
        tools,
        pending: /* @__PURE__ */ new Map()
      };
      this.#sessions.set(session2.threadId, session2);
      return session2;
    }
    const started = responseThread(await client.request("thread/start", {
      model: model.id,
      cwd: this.cwd,
      approvalPolicy: "never",
      sandbox: "read-only",
      baseInstructions: systemPrompt,
      dynamicTools: tools.declarations,
      ephemeral: false
    }));
    const session = {
      client,
      threadId: started.thread.id,
      modelId: model.id,
      toolSignature: tools.signature,
      tools,
      pending: /* @__PURE__ */ new Map()
    };
    this.#sessions.set(session.threadId, session);
    return session;
  }
  async #run(stream, model, context, options) {
    const transcript = collapseSystemMessages(context);
    const tools = buildDynamicTools(getCurrentTools(transcript.messages));
    let output = outputMessage(model);
    let session;
    let ended = false;
    let textIndex;
    let thinkingIndex;
    let toolEndTimer;
    const cleanup = () => {
      if (toolEndTimer !== void 0) clearTimeout(toolEndTimer);
      if (session) {
        session.client.off("request", onRequest);
        session.client.off("notification", onNotification);
        session.client.off("closed", onClosed);
      }
      options?.signal?.removeEventListener("abort", onAbort);
    };
    const fail = (error) => {
      if (ended) return;
      ended = true;
      cleanup();
      if (session) {
        session.client.close();
        this.#sessions.delete(session.threadId);
      }
      output.stopReason = options?.signal?.aborted ? "aborted" : "error";
      output.errorMessage = error instanceof Error ? error.message : "codex-bridge-error";
      stream.push({ type: "error", reason: output.stopReason, error: output });
      stream.end();
    };
    const finishToolBatch = () => {
      if (ended || !session || session.pending.size === 0) return;
      ended = true;
      cleanup();
      output.stopReason = "toolUse";
      stream.push({ type: "done", reason: "toolUse", message: output });
      stream.end();
    };
    const onRequest = (message) => {
      if (ended || !session || message.id === void 0 || typeof message.method !== "string") return;
      if (message.method !== "item/tool/call") {
        const key = message.method === "account/chatgptAuthTokens/refresh" ? "codex-credential-refresh-refused" : "codex-native-tool-refused";
        session.client.respondError(message.id, -32601, key);
        fail(new Error(`${key} method=${message.method}`));
        return;
      }
      try {
        const call = dynamicToolCall(message);
        if (call.threadId !== session.threadId || call.turnId !== session.activeTurnId) {
          throw new Error("codex-tool-call-session-mismatch");
        }
        if (call.namespace !== null) throw new Error("codex-tool-call-namespace-refused");
        const piToolName = session.tools.piNameByCodexName.get(call.tool);
        if (!piToolName) throw new Error(`codex-tool-call-unknown tool=${call.tool}`);
        if (session.pending.has(call.callId)) throw new Error(`codex-tool-call-duplicate call=${call.callId}`);
        session.pending.set(call.callId, { requestId: message.id, params: call, piToolName });
        const contentIndex = output.content.length;
        const toolCall = { type: "toolCall", id: call.callId, name: piToolName, arguments: call.arguments };
        output.content.push(toolCall);
        stream.push({ type: "toolcall_start", contentIndex, partial: output });
        stream.push({ type: "toolcall_end", contentIndex, toolCall, partial: output });
        if (toolEndTimer !== void 0) clearTimeout(toolEndTimer);
        toolEndTimer = setTimeout(finishToolBatch, 0);
      } catch (error) {
        session.client.respondError(message.id, -32602, "codex-tool-call-refused");
        fail(error);
      }
    };
    const onNotification = (message) => {
      if (ended || !session || typeof message.method !== "string") return;
      try {
        const params = asObject(message.params ?? {}, "notification");
        if (typeof params.threadId === "string" && params.threadId !== session.threadId) return;
        if (typeof params.turnId === "string" && session.activeTurnId && params.turnId !== session.activeTurnId) return;
        if (message.method === "item/agentMessage/delta") {
          if (typeof params.delta !== "string") throw new Error("codex-protocol-invalid-agent-delta");
          if (textIndex === void 0) {
            textIndex = output.content.length;
            output.content.push({ type: "text", text: "" });
            stream.push({ type: "text_start", contentIndex: textIndex, partial: output });
          }
          const content = output.content[textIndex];
          if (content.type !== "text") throw new Error("codex-text-state-invalid");
          content.text += params.delta;
          stream.push({ type: "text_delta", contentIndex: textIndex, delta: params.delta, partial: output });
          return;
        }
        if (message.method === "item/reasoning/summaryTextDelta") {
          if (typeof params.delta !== "string") throw new Error("codex-protocol-invalid-reasoning-delta");
          if (thinkingIndex === void 0) {
            thinkingIndex = output.content.length;
            output.content.push({ type: "thinking", thinking: "" });
            stream.push({ type: "thinking_start", contentIndex: thinkingIndex, partial: output });
          }
          const content = output.content[thinkingIndex];
          if (content.type !== "thinking") throw new Error("codex-thinking-state-invalid");
          content.thinking += params.delta;
          stream.push({ type: "thinking_delta", contentIndex: thinkingIndex, delta: params.delta, partial: output });
          return;
        }
        if (message.method === "thread/tokenUsage/updated") {
          updateUsage(output, params);
          return;
        }
        if (message.method !== "turn/completed") return;
        const turn = asObject(params.turn, "completed-turn");
        if (turn.id !== session.activeTurnId) return;
        if (turn.status === "completed") {
          ended = true;
          cleanup();
          if (thinkingIndex !== void 0) {
            const content = output.content[thinkingIndex];
            if (content.type === "thinking") stream.push({ type: "thinking_end", contentIndex: thinkingIndex, content: content.thinking, partial: output });
          }
          if (textIndex !== void 0) {
            const content = output.content[textIndex];
            if (content.type === "text") stream.push({ type: "text_end", contentIndex: textIndex, content: content.text, partial: output });
          }
          session.activeTurnId = void 0;
          output.stopReason = "stop";
          stream.push({ type: "done", reason: "stop", message: output });
          stream.end();
          return;
        }
        if (turn.status === "interrupted") {
          fail(new Error("codex-turn-interrupted"));
          return;
        }
        fail(new Error("codex-turn-failed"));
      } catch (error) {
        fail(error);
      }
    };
    const onClosed = () => fail(new Error("codex-app-server-closed"));
    const onAbort = () => {
      if (!session?.activeTurnId || ended) return;
      void session.client.request("turn/interrupt", {
        threadId: session.threadId,
        turnId: session.activeTurnId
      }).catch(fail);
    };
    try {
      const threadId = latestThreadId(transcript.messages);
      session = await this.#session(model, threadId, tools, getCurrentSystemPrompt(transcript.messages));
      output = outputMessage(model, session.threadId);
      stream.push({ type: "start", partial: output });
      session.client.on("request", onRequest);
      session.client.on("notification", onNotification);
      session.client.on("closed", onClosed);
      options?.signal?.addEventListener("abort", onAbort, { once: true });
      if (session.pending.size > 0) {
        const results = toolResultsAfterThreadMessage(transcript.messages, session.threadId);
        deliverToolResults(session.client, session.pending, results);
        return;
      }
      if (session.activeTurnId !== void 0) throw new Error("codex-turn-already-active");
      const turn = responseTurn(await session.client.request("turn/start", {
        threadId: session.threadId,
        input: inputAfterThreadMessage(transcript.messages, threadId),
        model: model.id,
        effort: options?.reasoning ?? null
      }));
      session.activeTurnId = turn.turn.id;
    } catch (error) {
      fail(error);
    }
  }
};

// src/models.ts
var PI_CONTEXT_ACCOUNTING_LIMIT = 128e3;
var PI_OUTPUT_ACCOUNTING_LIMIT = 32e3;
function buildPiModels(models) {
  return models.filter((model) => !model.hidden).map((model) => {
    const efforts = model.supportedReasoningEfforts.map((entry) => entry.reasoningEffort).filter((effort) => effort.length > 0);
    const thinkingLevelMap = Object.fromEntries(efforts.map((effort) => [effort, effort]));
    return {
      id: model.model,
      name: model.displayName,
      api: "codex-app-server",
      provider: "pi-codex",
      baseUrl: "codex-app-server",
      reasoning: efforts.length > 0,
      thinkingLevelMap,
      input: model.inputModalities.includes("image") ? ["text", "image"] : ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: PI_CONTEXT_ACCOUNTING_LIMIT,
      maxTokens: PI_OUTPUT_ACCOUNTING_LIMIT
    };
  });
}

// src/package-config.ts
import { existsSync as existsSync2, readFileSync } from "node:fs";
import { homedir as homedir2 } from "node:os";
import { dirname, join as join2, resolve } from "node:path";
var SETTINGS_CHANGED_EVENT = "kendex:extension-settings-changed";
var SETTINGS_RECHECK_MS = 1e3;
function expandHome(input) {
  if (input === "~") return homedir2();
  if (input.startsWith("~/")) return join2(homedir2(), input.slice(2));
  return input;
}
function rootAnchored(path, windows) {
  return windows ? /^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+)/.test(path) : path.startsWith("/");
}
var userDirMemo;
function userDir() {
  const agentDir = process.env.PI_CODING_AGENT_DIR;
  const home = process.env.HOME;
  const profile = process.env.USERPROFILE;
  const known = userDirMemo;
  if (known !== void 0 && known.agentDir === agentDir && known.home === home && known.profile === profile) return known;
  const override = expandHome(agentDir?.trim() || "");
  const dir = resolve(rootAnchored(override, process.platform === "win32") ? override : expandHome("~/.pi/agent"));
  userDirMemo = { agentDir, home, profile, dir, settings: join2(dir, "settings.json") };
  return userDirMemo;
}
var memo = /* @__PURE__ */ new Map();
function clearPackageConfigCache() {
  memo.clear();
  cwdSettings.clear();
  userSettingsMemo = void 0;
}
function openEntry(store, key, now) {
  const entry = store.get(key);
  return entry !== void 0 && now - entry.readAt < SETTINGS_RECHECK_MS ? entry : void 0;
}
function memoIn(store, key, now, compute, fingerprint, reusable) {
  const open = openEntry(store, key, now);
  if (open !== void 0) return open.value;
  const entry = store.get(key);
  const print = fingerprint?.();
  if (entry !== void 0 && print !== void 0 && entry.fingerprint === print) {
    entry.readAt = now;
    return entry.value;
  }
  const value = compute();
  store.set(key, { readAt: now, fingerprint: reusable === void 0 || reusable(value) ? print : void 0, value });
  return value;
}
function projectSettingsPath(cwd) {
  let current = resolve(cwd);
  while (true) {
    const candidate = join2(current, ".pi", "settings.json");
    if (existsSync2(candidate)) return candidate;
    if (existsSync2(join2(current, ".pi")) || existsSync2(join2(current, ".git")) || existsSync2(join2(current, ".kendex-lock.json"))) return candidate;
    const parent = dirname(current);
    if (parent === current) return join2(resolve(cwd), ".pi", "settings.json");
    current = parent;
  }
}
var PROJECT_TRUST_SYMBOL = /* @__PURE__ */ Symbol.for("kendex.pi.project-trust");
var trustRegistry;
function projectTrustRegistry() {
  if (trustRegistry !== void 0) return trustRegistry;
  const host = globalThis;
  trustRegistry = host[PROJECT_TRUST_SYMBOL] ?? {};
  host[PROJECT_TRUST_SYMBOL] = trustRegistry;
  return trustRegistry;
}
function settingsFileTrusted(settingsPath) {
  return projectTrustRegistry().projectSettings?.get(settingsPath) === true;
}
var userSettingsMemo;
function userSettingsPathAt(now) {
  const known = userSettingsMemo;
  if (known !== void 0 && now - known.readAt < SETTINGS_RECHECK_MS) return known.path;
  const path = userDir().settings;
  userSettingsMemo = { readAt: now, path };
  return path;
}
var pathListsUser;
var pathLists = /* @__PURE__ */ new Map();
function userAndProjectSettingsPathsAt(project, now) {
  const user = userSettingsPathAt(now);
  if (user !== pathListsUser) {
    pathLists.clear();
    pathListsUser = user;
  }
  let paths = pathLists.get(project);
  if (paths === void 0) {
    paths = Object.freeze(project === void 0 ? [user] : [user, project]);
    pathLists.set(project, paths);
  }
  return paths;
}
function isRecord(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}
function deepFreeze(value) {
  if (value && typeof value === "object" && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const child of Object.values(value)) deepFreeze(child);
  }
  return value;
}
function readText(path) {
  try {
    return { kind: "text", text: readFileSync(path, "utf8") };
  } catch (error) {
    const code = error?.code;
    if (code === "ENOENT" || code === "ENOTDIR") return { kind: "absent" };
    return { kind: "unreadable", error: error instanceof Error ? error.message : String(error) };
  }
}
var settingsFilesKeys = /* @__PURE__ */ new WeakMap();
function settingsFilesKey(paths) {
  let key = settingsFilesKeys.get(paths);
  if (key === void 0) {
    key = `settings-files\0${paths.join("\0")}`;
    settingsFilesKeys.set(paths, key);
  }
  return key;
}
function readSettingsFilesAt(paths, now) {
  const key = settingsFilesKey(paths);
  const open = openEntry(memo, key, now);
  if (open !== void 0) return open.value;
  let texts = [];
  return memoIn(
    memo,
    key,
    now,
    () => deepFreeze(
      paths.flatMap((path, index) => {
        const text = texts[index] ?? readText(path);
        if (text.kind === "absent") return [];
        if (text.kind === "unreadable") return [{ kind: "malformed", path, error: text.error }];
        try {
          const parsed = JSON.parse(text.text);
          return [{ kind: "parsed", path, settings: isRecord(parsed) ? parsed : {} }];
        } catch (error) {
          return [{ kind: "malformed", path, error: error instanceof Error ? error.message : String(error) }];
        }
      })
    ),
    () => {
      texts = paths.map(readText);
      return JSON.stringify(texts);
    }
  );
}
function packageConfigIn(settings, packageId) {
  const kendex = settings.kendex;
  const manager = isRecord(kendex) ? kendex.extensionManager : void 0;
  const config = isRecord(manager) ? manager.config : void 0;
  const own = isRecord(config) ? config[packageId] : void 0;
  return isRecord(own) ? own : void 0;
}
var cwdSettings = /* @__PURE__ */ new Map();
function cwdSettingsAt(cwd, now) {
  const known = cwdSettings.get(cwd);
  const open = known !== void 0 && now - known.readAt < SETTINGS_RECHECK_MS ? known : void 0;
  if (open !== void 0 && settingsFileTrusted(open.project) === open.trusted) return open;
  const project = open !== void 0 ? open.project : projectSettingsPath(cwd);
  const trusted = settingsFileTrusted(project);
  const paths = userAndProjectSettingsPathsAt(trusted ? project : void 0, now);
  const files = readSettingsFilesAt(paths, now);
  const filesReadAt = memo.get(settingsFilesKey(paths))?.readAt ?? now;
  const readAt = Math.min(open !== void 0 ? open.readAt : now, filesReadAt);
  const view = { readAt, project, trusted, paths, files, configs: configsOver(files) };
  cwdSettings.set(cwd, view);
  return view;
}
var configsByFiles = /* @__PURE__ */ new WeakMap();
function configsOver(files) {
  let configs = configsByFiles.get(files);
  if (!configs) {
    configs = /* @__PURE__ */ new Map();
    configsByFiles.set(files, configs);
  }
  return configs;
}
function packageConfigOver(packageId, files, configs) {
  const known = configs.get(packageId);
  if (known) return known;
  const merged = {};
  for (const file of files) {
    if (file.kind !== "parsed") continue;
    const config = packageConfigIn(file.settings, packageId);
    if (config) Object.assign(merged, config);
  }
  const frozen = Object.freeze(merged);
  configs.set(packageId, frozen);
  return frozen;
}
function readPackageConfig(packageId, cwd = process.cwd()) {
  const view = cwdSettingsAt(cwd, performance.now());
  return packageConfigOver(packageId, view.files, view.configs);
}
function installSettingsCacheRefresh(pi) {
  let unsubscribe;
  pi.on("session_start", () => {
    clearPackageConfigCache();
    unsubscribe ??= pi.events.on(SETTINGS_CHANGED_EVENT, () => clearPackageConfigCache());
  });
  pi.on("session_shutdown", () => {
    unsubscribe?.();
    unsubscribe = void 0;
    clearPackageConfigCache();
  });
}

// src/index.ts
var PACKAGE_ID = "@vanillagreen/pi-codex-bridge";
var OWNER = /* @__PURE__ */ Symbol.for("pi-codex-bridge:provider-owner");
var globalState = globalThis;
async function piCodexBridge(pi) {
  installSettingsCacheRefresh(pi);
  if (readPackageConfig(PACKAGE_ID).enabled === false) return;
  if (globalState[OWNER] !== void 0) return;
  globalState[OWNER] = true;
  const codexHome = resolveCodexHome();
  const bridge = new CodexBridge({ codexHome });
  try {
    let models = [];
    if (hasCodexLogin(codexHome)) {
      const discovery = await startAppServer(bridge.executable, codexHome);
      try {
        models = buildPiModels(await listCodexModels(discovery));
      } finally {
        discovery.close();
      }
    }
    const guardedStream = (...args) => {
      requireCodexLogin(codexHome);
      return bridge.streamSimple(...args);
    };
    const provider = piAi.createProvider({
      id: "pi-codex",
      name: "Pi Codex",
      baseUrl: "codex-app-server",
      auth: {
        apiKey: {
          name: "Codex CLI login",
          check: async () => hasCodexLogin(codexHome) ? { type: "api_key", source: "Codex CLI login" } : void 0,
          resolve: async () => hasCodexLogin(codexHome) ? { auth: {}, source: "Codex CLI login" } : void 0
        }
      },
      models,
      api: {
        stream: guardedStream,
        streamSimple: guardedStream
      }
    });
    pi.registerProvider(provider);
    pi.on("session_shutdown", async () => {
      await bridge.close();
      if (globalState[OWNER] === bridge) globalState[OWNER] = void 0;
    });
    globalState[OWNER] = bridge;
  } catch (error) {
    globalState[OWNER] = void 0;
    await bridge.close();
    throw error;
  }
}
export {
  piCodexBridge as default
};
