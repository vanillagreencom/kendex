// src/index.ts
import * as piAi from "@earendil-works/pi-ai";

// src/auth-presence.ts
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
var LOGIN_MISSING_KEY = "codex-login-missing";
function resolveCodexHome(env = process.env, userHome = homedir()) {
  const configured = env.CODEX_HOME?.trim();
  return configured ? configured : join(userHome, ".codex");
}
function hasCodexLogin(codexHome) {
  return existsSync(join(codexHome, "auth.json"));
}
function requireCodexLogin(codexHome) {
  if (!hasCodexLogin(codexHome)) {
    throw new Error(`${LOGIN_MISSING_KEY} home=${codexHome}
Sign in with the Codex CLI first: codex login`);
  }
}

// src/bridge.ts
import {
  collapseSystemMessages,
  createAssistantMessageEventStream,
  getCurrentSystemPrompt,
  getCurrentTools
} from "@earendil-works/pi-ai";

// src/app-server.ts
import { execFile, spawn as nodeSpawn } from "node:child_process";
import { promisify } from "node:util";

// src/codex-policy.ts
var SUPPORTED_CODEX_VERSION = "0.163.0";
var DISABLED_FEATURES = [
  "shell_tool",
  "apps",
  "plugins",
  "remote_plugin",
  "multi_agent",
  "browser_use",
  "computer_use",
  "image_generation",
  "view_image",
  "sleep_tool",
  "hooks",
  "unified_exec",
  "unified_exec_tty",
  "write_stdin_approval",
  "shell_snapshot",
  "code_mode_host",
  "code_mode_interrupt",
  "workspace_dependencies",
  "worktrees",
  "in_app_local_automation",
  "browser_use_external",
  "browser_use_full_cdp_access",
  "in_app_browser",
  "browser_annotation_api",
  "skill_mcp_dependency_install",
  "tool_call_mcp_elicitation",
  "auth_elicitation",
  "tool_suggest",
  "skill_search",
  "goals",
  "guardian_approval",
  "daemon_auto_start",
  "in_app_chat",
  "in_app_dictation",
  "in_app_voice",
  "in_app_updates",
  "realtime_conversation"
];
var REVIEWED_ENABLED_FEATURES = /* @__PURE__ */ new Map([
  // `--disable unified_exec`, `-c features.unified_exec=false` and
  // `experimental_use_unified_exec_tool=false` all leave it reported on in
  // 0.163.0. Its exec_command and write_stdin tools are not offered while
  // shell_tool is off and the thread has no environment; the fixture suite
  // reads the tools Codex offers the model to hold that.
  ["unified_exec", "tools not offered: shell_tool off, environments []"],
  ["api_key_cyber_access_programs", "API-key access programs; no tool"],
  ["api_key_model_discovery", "API-key model listing; no tool"],
  ["cli_daybreak", "access-program selection; no tool"],
  ["compaction_image_budget", "compaction image budget; no tool"],
  ["content_item_kinds", "content item kinds; no tool"],
  ["enable_request_compression", "request compression; no tool"],
  ["fast_mode", "service tier; no tool"],
  ["ultrafast_mode", "service tier; no tool"],
  ["guardian_reuse_parent_compaction", "guardian setting; guardian_approval is off"],
  ["instant_interrupt", "interrupt latency; no tool"],
  ["mentions_v2", "input mention parsing; no tool"],
  ["plugin_sharing", "plugin sharing; plugins are off"],
  ["system_proxy_fallback", "proxy transport; no tool"],
  ["unbounded_connection_retries", "transport retries; no tool"],
  ["collaboration_modes", "stage removed in 0.163.0"],
  ["item_ids", "stage removed in 0.163.0"],
  ["resize_all_images", "stage removed in 0.163.0"],
  ["sqlite", "stage removed in 0.163.0"],
  ["steer", "stage removed in 0.163.0"],
  ["terminal_resize_reflow", "stage removed in 0.163.0"],
  ["tool_search_always_defer_mcp_tools", "stage removed in 0.163.0"],
  ["tui_app_server", "stage removed in 0.163.0"]
]);
var ALLOWED_ITEM_TYPES = /* @__PURE__ */ new Set([
  "userMessage",
  "agentMessage",
  "reasoning",
  "plan",
  "contextCompaction",
  "dynamicToolCall"
]);
var APPROVAL_POLICY = "untrusted";
var LAUNCH_CONFIG = [
  'web_search="disabled"',
  "tools.experimental_request_user_input={enabled=false}"
];
function appServerArgs(configOverrides) {
  return [
    "app-server",
    "--stdio",
    ...DISABLED_FEATURES.flatMap((feature) => ["--disable", feature]),
    ...LAUNCH_CONFIG.flatMap((setting) => ["-c", setting]),
    ...configOverrides.flatMap((override) => ["-c", override])
  ];
}
function threadConfig(mcpServerNames) {
  return {
    mcp_servers: Object.fromEntries(mcpServerNames.map((name) => [name, { enabled: false }]))
  };
}
function unreviewedFeature(enabled) {
  return [...enabled].sort().find((name) => !REVIEWED_ENABLED_FEATURES.has(name));
}

// src/codex-environment.ts
var INHERITED = /* @__PURE__ */ new Set([
  "PATH",
  "HOME",
  "LANG",
  "LANGUAGE",
  "TMPDIR",
  "HTTP_PROXY",
  "HTTPS_PROXY",
  "ALL_PROXY",
  "NO_PROXY",
  "http_proxy",
  "https_proxy",
  "all_proxy",
  "no_proxy",
  "SSL_CERT_FILE",
  "SSL_CERT_DIR",
  "NODE_EXTRA_CA_CERTS",
  "REQUESTS_CA_BUNDLE",
  "CURL_CA_BUNDLE"
]);
function inherited(name) {
  return INHERITED.has(name) || name.startsWith("LC_");
}
function codexChildEnvironment(codexHome, env = process.env) {
  const child = {};
  for (const [name, value] of Object.entries(env)) {
    if (value !== void 0 && inherited(name)) child[name] = value;
  }
  child.CODEX_HOME = codexHome;
  return child;
}

// src/json-rpc.ts
import { EventEmitter } from "node:events";
import { createInterface } from "node:readline";

// src/protocol.ts
function invalid(method, field) {
  return new Error(`codex-protocol-invalid method=${method} field=${field}`);
}
function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function object(value, method, field) {
  if (!isObject(value)) throw invalid(method, field);
  return value;
}
function string(value, method, field) {
  if (typeof value !== "string") throw invalid(method, field);
  return value;
}
function nullableString(value, method, field) {
  if (value === null || value === void 0) return null;
  return string(value, method, field);
}
function array(value, method, field) {
  if (!Array.isArray(value)) throw invalid(method, field);
  return value;
}
function count(value, method, field) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) throw invalid(method, field);
  return value;
}
function requestId(value) {
  if (typeof value === "string" || typeof value === "number" && Number.isInteger(value)) return value;
  throw invalid("jsonrpc", "id");
}
function decodeFrame(value, decodeResult) {
  const frame = object(value, "jsonrpc", "frame");
  const method = frame.method;
  if (method === void 0) {
    const id = requestId(frame.id);
    if (frame.error !== void 0) {
      const error = isObject(frame.error) ? frame.error : {};
      return {
        kind: "error",
        id,
        code: typeof error.code === "number" ? error.code : null,
        message: typeof error.message === "string" ? error.message : ""
      };
    }
    return { kind: "response", id, result: decodeResult(id, frame.result) };
  }
  const name = string(method, "jsonrpc", "method");
  const params = frame.params === void 0 || frame.params === null ? {} : object(frame.params, name, "params");
  if (frame.id === void 0) return { kind: "notification", method: name, params };
  return { kind: "request", id: requestId(frame.id), method: name, params };
}
function decodeVersion(stdout) {
  const match = /^codex-cli (\S+)\s*$/.exec(stdout);
  if (!match) throw invalid("--version", "stdout");
  return match[1];
}
function decodeModelPage(result) {
  const method = "model/list";
  const page = object(result, method, "result");
  const models = array(page.data, method, "data").map((raw) => {
    const model = object(raw, method, "data[]");
    return {
      model: string(model.model, method, "data[].model"),
      displayName: string(model.displayName, method, "data[].displayName"),
      hidden: model.hidden === true,
      inputModalities: array(model.inputModalities, method, "data[].inputModalities").map((entry) => string(entry, method, "data[].inputModalities[]")),
      reasoningEfforts: array(model.supportedReasoningEfforts, method, "data[].supportedReasoningEfforts").map((entry) => string(object(entry, method, "data[].supportedReasoningEfforts[]").reasoningEffort, method, "data[].supportedReasoningEfforts[].reasoningEffort"))
    };
  });
  return { models, nextCursor: nullableString(page.nextCursor, method, "nextCursor") };
}
function decodeThreadStart(result) {
  const method = "thread/start";
  const thread = object(object(result, method, "result").thread, method, "thread");
  return { threadId: string(thread.id, method, "thread.id") };
}
function decodeThreadResume(result) {
  const method = "thread/resume";
  const response = object(result, method, "result");
  const thread = object(response.thread, method, "thread");
  const page = object(response.initialTurnsPage, method, "initialTurnsPage");
  const turns = array(page.data, method, "initialTurnsPage.data");
  const last = turns.length === 0 ? null : string(object(turns[0], method, "initialTurnsPage.data[0]").id, method, "initialTurnsPage.data[0].id");
  return { threadId: string(thread.id, method, "thread.id"), lastTurnId: last };
}
function decodeTurnStart(result) {
  const method = "turn/start";
  const turn = object(object(result, method, "result").turn, method, "turn");
  return { turnId: string(turn.id, method, "turn.id") };
}
function decodeMcpServerNames(result) {
  const method = "config/read";
  const config = object(object(result, method, "result").config, method, "config");
  const servers = config.mcp_servers;
  if (servers === void 0 || servers === null) return [];
  return Object.keys(object(servers, method, "config.mcp_servers")).sort();
}
function decodeFeaturePage(result) {
  const method = "experimentalFeature/list";
  const page = object(result, method, "result");
  const enabled = [];
  for (const raw of array(page.data, method, "data")) {
    const feature = object(raw, method, "data[]");
    const name = string(feature.name, method, "data[].name");
    if (typeof feature.enabled !== "boolean") throw invalid(method, "data[].enabled");
    if (feature.enabled) enabled.push(name);
  }
  return { enabled, nextCursor: nullableString(page.nextCursor, method, "nextCursor") };
}
function decodeDynamicToolCall(params) {
  const method = "item/tool/call";
  return {
    threadId: string(params.threadId, method, "threadId"),
    turnId: string(params.turnId, method, "turnId"),
    callId: string(params.callId, method, "callId"),
    namespace: nullableString(params.namespace, method, "namespace"),
    tool: string(params.tool, method, "tool"),
    arguments: object(params.arguments, method, "arguments")
  };
}
function requestThreadId(params) {
  return typeof params.threadId === "string" ? params.threadId : null;
}
function usage(value, method) {
  const last = object(object(value, method, "tokenUsage").last, method, "tokenUsage.last");
  return {
    input: count(last.inputTokens, method, "tokenUsage.last.inputTokens"),
    output: count(last.outputTokens, method, "tokenUsage.last.outputTokens"),
    cacheRead: count(last.cachedInputTokens, method, "tokenUsage.last.cachedInputTokens"),
    cacheWrite: count(last.cacheWriteInputTokens, method, "tokenUsage.last.cacheWriteInputTokens"),
    total: count(last.totalTokens, method, "tokenUsage.last.totalTokens")
  };
}
function decodeEvent(method, params) {
  switch (method) {
    case "item/agentMessage/delta":
    case "item/reasoning/summaryTextDelta":
      return {
        type: method === "item/agentMessage/delta" ? "agentDelta" : "reasoningDelta",
        threadId: string(params.threadId, method, "threadId"),
        turnId: string(params.turnId, method, "turnId"),
        itemId: string(params.itemId, method, "itemId"),
        delta: string(params.delta, method, "delta")
      };
    case "item/started": {
      const item = object(params.item, method, "item");
      return {
        type: "itemStarted",
        threadId: string(params.threadId, method, "threadId"),
        turnId: string(params.turnId, method, "turnId"),
        itemType: string(item.type, method, "item.type")
      };
    }
    case "item/completed": {
      const item = object(params.item, method, "item");
      if (item.type !== "agentMessage") return { type: "ignored", method };
      return {
        type: "agentMessageCompleted",
        threadId: string(params.threadId, method, "threadId"),
        turnId: string(params.turnId, method, "turnId"),
        itemId: string(item.id, method, "item.id"),
        text: string(item.text, method, "item.text")
      };
    }
    case "turn/started":
      return {
        type: "turnStarted",
        threadId: string(params.threadId, method, "threadId"),
        turnId: string(object(params.turn, method, "turn").id, method, "turn.id")
      };
    case "turn/completed": {
      const turn = object(params.turn, method, "turn");
      const status = string(turn.status, method, "turn.status");
      if (status !== "completed" && status !== "interrupted" && status !== "failed") throw invalid(method, "turn.status");
      const error = turn.error === null || turn.error === void 0 ? null : object(turn.error, method, "turn.error");
      return {
        type: "turnCompleted",
        threadId: string(params.threadId, method, "threadId"),
        turnId: string(turn.id, method, "turn.id"),
        status,
        error: error === null ? null : nullableString(error.message, method, "turn.error.message")
      };
    }
    case "thread/tokenUsage/updated":
      return {
        type: "tokenUsage",
        threadId: string(params.threadId, method, "threadId"),
        turnId: string(params.turnId, method, "turnId"),
        usage: usage(params.tokenUsage, method)
      };
    case "mcpServer/startupStatus/updated":
      return {
        type: "mcpStartup",
        name: string(params.name, method, "name"),
        status: string(params.status, method, "status")
      };
    default:
      return { type: "ignored", method };
  }
}

// src/json-rpc.ts
function firstLine(text2) {
  return text2.split("\n", 1)[0].slice(0, 300);
}
var CodexProtocolClient = class extends EventEmitter {
  #child;
  #killGroup;
  #nextId = 0;
  #pending = /* @__PURE__ */ new Map();
  #closed = false;
  #killReason;
  /** `killGroup` is true when the child leads its own process group. */
  constructor(child, killGroup) {
    super();
    this.#child = child;
    this.#killGroup = killGroup;
    const lines = createInterface({ input: child.stdout, crlfDelay: Infinity });
    lines.on("line", (line) => this.#receive(line));
    child.stderr.resume();
    child.stdin.on("error", () => void 0);
    child.once("error", (error) => {
      this.#close(new Error(`codex-spawn-failed code=${error.code ?? "unknown"}`));
    });
    child.once("exit", (code, signal) => {
      this.#close(this.#killReason ?? new Error(`codex-app-server-exit code=${code ?? "null"} signal=${signal ?? "null"}`));
    });
  }
  request(method, params) {
    return this.#send(method, params, void 0);
  }
  requestDecoded(method, params, decode) {
    return this.#send(method, params, decode);
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
  kill(reason) {
    this.#killReason ??= reason;
    const child = this.#child;
    if (child.exitCode === null && child.signalCode === null && child.pid !== void 0) {
      try {
        if (this.#killGroup) process.kill(-child.pid, "SIGKILL");
        else child.kill("SIGKILL");
      } catch {
        child.kill("SIGKILL");
      }
    }
    this.#close(reason);
  }
  #send(method, params, decode) {
    if (this.#closed) return Promise.reject(this.#killReason ?? new Error("codex-app-server-closed"));
    const id = this.#nextId++;
    return new Promise((resolve2, reject) => {
      this.#pending.set(id, { method, decode, resolve: resolve2, reject });
      this.#write({ method, id, params });
    });
  }
  #write(message) {
    if (this.#closed) return;
    this.#child.stdin.write(`${JSON.stringify(message)}
`);
  }
  #decodeResult(id, result) {
    const decode = this.#pending.get(id)?.decode;
    if (decode === void 0) return result;
    try {
      return { decoded: decode(result) };
    } catch (error) {
      return { failed: error instanceof Error ? error : new Error("codex-protocol-decode-failed") };
    }
  }
  #receive(line) {
    if (this.#closed) return;
    let frame;
    try {
      frame = JSON.parse(line, (key, value) => key === "" ? decodeFrame(value, (id, result) => this.#decodeResult(id, result)) : value);
    } catch (error) {
      this.kill(new Error(error instanceof SyntaxError ? "codex-protocol-invalid-json" : error.message));
      return;
    }
    if (frame.kind === "response" || frame.kind === "error") {
      const pending = this.#pending.get(frame.id);
      if (!pending) return;
      this.#pending.delete(frame.id);
      if (frame.kind === "error") {
        const detail = pending.decode === void 0 && frame.message ? `
${firstLine(frame.message)}` : "";
        pending.reject(new Error(`codex-request-failed method=${pending.method} code=${frame.code ?? "null"}${detail}`));
        return;
      }
      if (pending.decode === void 0) {
        pending.resolve(frame.result);
        return;
      }
      const outcome = frame.result;
      if (outcome.failed) pending.reject(outcome.failed);
      else pending.resolve(outcome.decoded);
      return;
    }
    this.emit(frame.kind, frame);
  }
  #close(error) {
    if (this.#closed) return;
    this.#closed = true;
    for (const pending of this.#pending.values()) pending.reject(error);
    this.#pending.clear();
    this.emit("closed", error);
  }
};

// src/app-server.ts
var execFileAsync = promisify(execFile);
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
async function assertSupportedCodex(launch) {
  let stdout;
  try {
    ({ stdout } = await execFileAsync(launch.executable, ["--version"], {
      env: codexChildEnvironment(launch.codexHome, launch.env),
      encoding: "utf8",
      maxBuffer: 4096,
      timeout: 1e4
    }));
  } catch (error) {
    throw new Error(`codex-version-unreadable executable=${launch.executable} code=${error.code ?? "unknown"}`);
  }
  const found = decodeVersion(stdout);
  if (found !== SUPPORTED_CODEX_VERSION) {
    throw new Error(`codex-version-unsupported found=${found} expected=${SUPPORTED_CODEX_VERSION}`);
  }
}
async function startAppServer(launch, spawn = nodeSpawn) {
  await assertSupportedCodex(launch);
  const group = process.platform !== "win32";
  const child = spawn(launch.executable, appServerArgs(launch.configOverrides), {
    cwd: launch.cwd,
    env: codexChildEnvironment(launch.codexHome, launch.env),
    detached: group,
    windowsHide: true
  });
  const client = new CodexProtocolClient(child, group);
  await client.request("initialize", INITIALIZE_PARAMS);
  client.notify("initialized");
  return client;
}
async function listCodexModels(client) {
  const models = [];
  let cursor = null;
  do {
    const page = await client.requestDecoded("model/list", { includeHidden: false, ...cursor === null ? {} : { cursor } }, decodeModelPage);
    models.push(...page.models);
    cursor = page.nextCursor;
  } while (cursor !== null);
  return models;
}

// src/dynamic-tools.ts
import { createHash } from "node:crypto";
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
    declarations.push({ type: "function", name, description: tool.description, inputSchema: tool.parameters });
  }
  const signature = createHash("sha256").update(JSON.stringify(declarations)).digest("hex").slice(0, 16);
  return { declarations, piNameByCodexName, signature };
}

// src/models.ts
import { clampThinkingLevel } from "@earendil-works/pi-ai";
var PROVIDER_ID = "pi-codex";
var API_ID = "codex-app-server";
var PI_CONTEXT_ACCOUNTING_LIMIT = 128e3;
var PI_OUTPUT_ACCOUNTING_LIMIT = 32e3;
var PI_LEVELS = ["minimal", "low", "medium", "high", "xhigh", "max"];
function thinkingLevelMap(efforts) {
  const map = { off: efforts.includes("none") ? "none" : null };
  for (const level of PI_LEVELS) map[level] = efforts.includes(level) ? level : null;
  return map;
}
function buildPiModels(models) {
  return models.filter((model) => !model.hidden).map((model) => {
    const efforts = model.reasoningEfforts.filter((effort) => effort.length > 0);
    return {
      id: model.model,
      name: model.displayName,
      api: API_ID,
      provider: PROVIDER_ID,
      baseUrl: API_ID,
      reasoning: efforts.length > 0,
      thinkingLevelMap: thinkingLevelMap(efforts),
      input: model.inputModalities.includes("image") ? ["text", "image"] : ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: PI_CONTEXT_ACCOUNTING_LIMIT,
      maxTokens: PI_OUTPUT_ACCOUNTING_LIMIT
    };
  });
}
function codexEffort(model, level) {
  if (!model.reasoning) return null;
  const clamped = level === void 0 ? "off" : clampThinkingLevel(model, level);
  return model.thinkingLevelMap?.[clamped] ?? null;
}

// src/tool-pairing.ts
var LOST_TOOL_RESULT_TEXT = "tool-result-lost=interrupted\nPi Codex bridge: the result of this tool call was lost (the turn was interrupted). Treat the call as failed; it may or may not have executed. Run the tool again if its output is still needed.";
function contentItems(result) {
  const items = result.content.map((item) => item.type === "text" ? { type: "inputText", text: item.text } : { type: "inputImage", imageUrl: `data:${item.mimeType};base64,${item.data}` });
  return items.length > 0 ? items : [{ type: "inputText", text: "" }];
}
function answerToolCalls(pending, results) {
  const byCall = new Map(pending.map((call) => [call.callId, call]));
  const resultByCall = /* @__PURE__ */ new Map();
  for (const result of results) {
    if (resultByCall.has(result.toolCallId)) throw new Error(`codex-tool-result-duplicate call=${result.toolCallId}`);
    const call = byCall.get(result.toolCallId);
    if (!call) throw new Error(`codex-tool-result-unmatched call=${result.toolCallId}`);
    if (call.piToolName !== result.toolName) throw new Error(`codex-tool-result-name-mismatch call=${result.toolCallId}`);
    resultByCall.set(result.toolCallId, result);
  }
  return pending.map((call) => {
    const result = resultByCall.get(call.callId);
    return {
      requestId: call.requestId,
      result: result ? { contentItems: contentItems(result), success: !result.isError } : { contentItems: [{ type: "inputText", text: LOST_TOOL_RESULT_TEXT }], success: false }
    };
  });
}

// src/transcript.ts
var RESPONSE_ID_PREFIX = "codex-thread";
function encodeResponseId(threadId, turnId, toolSignature) {
  return `${RESPONSE_ID_PREFIX}:${threadId}:${turnId}:${toolSignature}`;
}
function findBoundary(messages) {
  for (let index = messages.length - 1; index >= 0; index--) {
    const message = messages[index];
    if (message.role !== "assistant" || message.provider !== PROVIDER_ID) continue;
    if (message.stopReason !== "stop" && message.stopReason !== "toolUse") continue;
    const parts = message.responseId?.split(":");
    if (parts?.length !== 4 || parts[0] !== RESPONSE_ID_PREFIX || parts.some((part) => part.length === 0)) continue;
    return { index, threadId: parts[1], turnId: parts[2], toolSignature: parts[3], stopReason: message.stopReason };
  }
  return void 0;
}
function userInput(content) {
  if (typeof content === "string") return [{ type: "text", text: content, text_elements: [] }];
  return content.map((item) => item.type === "text" ? { type: "text", text: item.text, text_elements: [] } : { type: "image", url: `data:${item.mimeType};base64,${item.data}` });
}
function afterBoundary(messages, boundary) {
  const later = messages.slice(boundary.index + 1);
  return {
    input: later.flatMap((message) => message.role === "user" ? userInput(message.content) : []),
    toolResults: later.filter((message) => message.role === "toolResult")
  };
}
function text(content) {
  if (typeof content === "string") return content;
  return content.flatMap((item) => item.type === "text" && typeof item.text === "string" ? [item.text] : []).join("\n");
}
function historyEntry(message) {
  if (message.role === "user") return `User:
${text(message.content)}`;
  if (message.role === "toolResult") return `Tool result (${message.toolName}):
${text(message.content)}`;
  const parts = message.content.flatMap((item) => {
    if (item.type === "text") return [item.text];
    if (item.type === "toolCall") return [`[called ${item.name} ${JSON.stringify(item.arguments)}]`];
    return [];
  });
  return `Assistant:
${parts.join("\n")}`;
}
function historyImages(message) {
  if (message.role !== "user" && message.role !== "toolResult") return [];
  if (typeof message.content === "string") return [];
  return message.content.flatMap((item) => item.type === "image" ? [{ type: "image", url: `data:${item.mimeType};base64,${item.data}` }] : []);
}
function replayInput(messages) {
  const conversation = messages.filter((message) => message.role !== "system");
  let start = conversation.length;
  while (start > 0 && conversation[start - 1].role === "user") start--;
  const history = conversation.slice(0, start);
  const trailing = conversation.slice(start).flatMap((message) => message.role === "user" ? userInput(message.content) : []);
  if (history.length === 0) return trailing;
  const replay = `Conversation so far, replayed from Pi:

${history.map(historyEntry).join("\n\n")}`;
  return [{ type: "text", text: replay, text_elements: [] }, ...history.flatMap(historyImages), ...trailing];
}

// src/bridge.ts
var MAX_THREADS = 16;
var MAX_QUEUED_EVENTS = 1024;
var MAX_PENDING_CALLS = 64;
var DISCOVERY_DEADLINE_MS = 15e3;
var ThreadQueue = class {
  #items = [];
  #wake;
  #full = false;
  push(item) {
    if (this.#full) return;
    if (this.#items.length >= MAX_QUEUED_EVENTS - 1) {
      this.#full = true;
      this.#items.push({ kind: "refusal", error: new Error(`codex-request-queue-full limit=${MAX_QUEUED_EVENTS}`), turnId: null });
    } else {
      this.#items.push(item);
    }
    this.#wake?.();
  }
  async next() {
    while (this.#items.length === 0) await new Promise((resolve2) => this.#wake = resolve2);
    this.#wake = void 0;
    return this.#items.shift();
  }
  /** The tool call at the head of the queue, taken, if one is there. */
  takeToolCall() {
    const head = this.#items[0];
    if (head?.kind !== "toolCall") return void 0;
    this.#items.shift();
    return head;
  }
};
function emptyUsage() {
  return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
}
function firstLine2(error) {
  return (error instanceof Error ? error.message : "codex-bridge-error").split("\n", 1)[0];
}
var CodexBridge = class {
  codexHome;
  #launch;
  #connect;
  #client;
  #current;
  #threads = /* @__PURE__ */ new Map();
  constructor(options) {
    this.codexHome = options.codexHome;
    this.#launch = {
      executable: options.executable ?? "codex",
      codexHome: options.codexHome,
      cwd: options.cwd ?? process.cwd(),
      env: options.env ?? process.env,
      configOverrides: options.configOverrides ?? []
    };
    this.#connect = options.connect ?? ((launch) => startAppServer(launch));
  }
  /** Pi's stream entry point. A missing login throws before any process starts. */
  streamSimple = (model, context, options) => {
    requireCodexLogin(this.codexHome);
    const stream = createAssistantMessageEventStream();
    void this.#run(stream, model, context, options);
    return stream;
  };
  /** The account's models through this bridge's own client, bounded by a
   * deadline so a stalled Codex cannot hold Pi's startup. */
  async discoverModels(deadlineMs = DISCOVERY_DEADLINE_MS) {
    let timer;
    const deadline = new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`codex-discovery-timeout after_ms=${deadlineMs}`)), deadlineMs);
    });
    try {
      const client = await Promise.race([this.#client ??= this.#open(), deadline]);
      return { models: await Promise.race([listCodexModels(client), deadline]) };
    } catch (error) {
      this.#closeClient(error instanceof Error ? error : new Error("codex-discovery-failed"));
      return { models: [], notice: firstLine2(error) };
    } finally {
      clearTimeout(timer);
    }
  }
  async close() {
    this.#closeClient(new Error("codex-bridge-closed"));
    this.#threads.clear();
  }
  // --- Client and router ---------------------------------------------------
  #open() {
    const opening = this.#connect(this.#launch).then((client) => {
      if (this.#client !== opening) {
        client.kill(new Error("codex-bridge-closed"));
        throw new Error("codex-bridge-closed");
      }
      this.#current = client;
      client.on("request", (frame) => this.#onRequest(client, frame));
      client.on("notification", (frame) => this.#onNotification(client, frame));
      client.on("closed", (error) => this.#onClosed(client, error));
      return client;
    });
    opening.catch(() => {
      if (this.#client === opening) this.#client = void 0;
    });
    return opening;
  }
  #closeClient(reason) {
    const opening = this.#client;
    this.#client = void 0;
    this.#current?.kill(reason);
    this.#current = void 0;
    opening?.then((client) => client.kill(reason), () => void 0);
  }
  #onClosed(client, error) {
    if (this.#current !== client) return;
    this.#current = void 0;
    this.#client = void 0;
    for (const record of this.#threads.values()) record.queue.push({ kind: "refusal", error, turnId: null });
    this.#threads.clear();
  }
  /** A guard that cannot be held by refusing one turn: stop the child and
   * every process it started, and fail every stream on it. */
  #breach(client, error) {
    client.kill(error);
  }
  #interrupt(client, record) {
    if (record.activeTurnId === null) return;
    void client.request("turn/interrupt", { threadId: record.threadId, turnId: record.activeTurnId }).catch(() => void 0);
  }
  /** Refuse the turn a server request belongs to; a request no thread of
   * this bridge owns is a breach. */
  #refuse(client, threadId, error) {
    const records = threadId === null ? [...this.#threads.values()].filter((record) => record.activeTurnId !== null) : [this.#threads.get(threadId)];
    for (const record of records) {
      if (record === void 0) {
        this.#breach(client, new Error(`codex-foreign-thread thread=${threadId}`));
        return;
      }
      this.#interrupt(client, record);
      record.queue.push({ kind: "refusal", error, turnId: record.activeTurnId });
    }
  }
  #onNotification(client, frame) {
    let event;
    try {
      event = decodeEvent(frame.method, frame.params);
    } catch (error) {
      this.#breach(client, error);
      return;
    }
    if (event.type === "ignored") return;
    if (event.type === "mcpStartup") {
      if (event.status === "starting") this.#breach(client, new Error(`codex-mcp-started name=${event.name}`));
      return;
    }
    const record = this.#threads.get(event.threadId);
    if (record === void 0) {
      if (event.type === "turnStarted" || event.type === "itemStarted") {
        this.#breach(client, new Error(`codex-foreign-thread thread=${event.threadId}`));
      }
      return;
    }
    if (event.type === "itemStarted" && !ALLOWED_ITEM_TYPES.has(event.itemType)) {
      this.#interrupt(client, record);
      record.queue.push({ kind: "refusal", error: new Error(`codex-native-item type=${event.itemType}`), turnId: event.turnId });
      return;
    }
    record.queue.push({ kind: "event", event, raw: frame });
  }
  #onRequest(client, frame) {
    const { id, method, params } = frame;
    if (method === "item/tool/call") {
      let call;
      try {
        call = decodeDynamicToolCall(params);
      } catch (error2) {
        client.respondError(id, -32602, "codex-tool-call-refused");
        this.#refuse(client, requestThreadId(params), error2);
        return;
      }
      const record = this.#threads.get(call.threadId);
      if (record === void 0) {
        client.respondError(id, -32602, "codex-tool-call-refused");
        this.#breach(client, new Error(`codex-foreign-thread thread=${call.threadId}`));
        return;
      }
      record.queue.push({ kind: "toolCall", requestId: id, call, raw: frame });
      return;
    }
    let error;
    if (method === "item/commandExecution/requestApproval" || method === "item/fileChange/requestApproval") {
      client.respond(id, { decision: "decline" });
      error = new Error(`codex-native-approval-declined method=${method}`);
    } else if (method === "execCommandApproval" || method === "applyPatchApproval") {
      client.respond(id, { decision: "abort" });
      error = new Error(`codex-native-approval-declined method=${method}`);
    } else if (method === "account/chatgptAuthTokens/refresh") {
      client.respondError(id, -32601, "codex-credential-refresh-refused");
      error = new Error(`codex-credential-refresh-refused method=${method}`);
    } else {
      client.respondError(id, -32601, "codex-server-request-refused");
      error = new Error(`codex-server-request-refused method=${method}`);
    }
    this.#refuse(client, requestThreadId(params), error);
  }
  // --- Threads -------------------------------------------------------------
  #register(record) {
    this.#threads.delete(record.threadId);
    this.#threads.set(record.threadId, record);
    while (this.#threads.size > MAX_THREADS) {
      const idle = [...this.#threads.values()].filter((candidate) => candidate !== record && !candidate.streaming && candidate.activeTurnId === null).sort((a, b) => a.lastUsed - b.lastUsed)[0];
      if (idle === void 0) throw new Error(`codex-thread-table-full limit=${MAX_THREADS}`);
      this.#threads.delete(idle.threadId);
    }
  }
  #record(threadId, tools, lastTurnId) {
    return { threadId, tools, lastTurnId, activeTurnId: null, pending: [], queue: new ThreadQueue(), streaming: false, lastUsed: Date.now() };
  }
  /** Answer a turn the bridge no longer continues, so Codex does not wait on
   * it, and stop it. */
  #abandon(client, record) {
    for (const answer of answerToolCalls(record.pending, [])) client.respond(answer.requestId, answer.result);
    record.pending = [];
    this.#interrupt(client, record);
    record.activeTurnId = null;
  }
  /** Names only: `config/read` is decoded to the configured MCP server names
   * inside its own parse. A read that fails refuses the thread. */
  async #mcpServerNames(client) {
    try {
      return await client.requestDecoded("config/read", { cwd: this.#launch.cwd }, decodeMcpServerNames);
    } catch (error) {
      throw new Error(`codex-mcp-names-unread
${firstLine2(error)}`);
    }
  }
  /** Refuse a thread on which any feature no review covers is enabled, before
   * its first turn. */
  async #auditFeatures(client, threadId) {
    const enabled = [];
    let cursor = null;
    do {
      const page = await client.requestDecoded("experimentalFeature/list", { threadId, ...cursor === null ? {} : { cursor } }, decodeFeaturePage);
      enabled.push(...page.enabled);
      cursor = page.nextCursor;
    } while (cursor !== null);
    const unreviewed = unreviewedFeature(enabled);
    if (unreviewed !== void 0) throw new Error(`codex-feature-unreviewed name=${unreviewed}`);
  }
  async #startThread(client, model, messages, tools) {
    const names = await this.#mcpServerNames(client);
    const { threadId } = await client.requestDecoded("thread/start", {
      model: model.id,
      cwd: this.#launch.cwd,
      approvalPolicy: APPROVAL_POLICY,
      sandbox: "read-only",
      baseInstructions: getCurrentSystemPrompt(messages),
      dynamicTools: tools.declarations,
      ephemeral: false,
      environments: [],
      config: threadConfig(names)
    }, decodeThreadStart);
    const record = this.#record(threadId, tools, null);
    this.#register(record);
    try {
      await this.#auditFeatures(client, threadId);
    } catch (error) {
      this.#threads.delete(threadId);
      throw error;
    }
    return record;
  }
  /** A cold resume, used only when Codex's latest turn is Pi's boundary. */
  async #resumeThread(client, model, threadId, turnId, tools) {
    const names = await this.#mcpServerNames(client);
    const resumed = await client.requestDecoded("thread/resume", {
      threadId,
      model: model.id,
      cwd: this.#launch.cwd,
      approvalPolicy: APPROVAL_POLICY,
      sandbox: "read-only",
      config: threadConfig(names),
      excludeTurns: true,
      initialTurnsPage: { limit: 1, sortDirection: "desc", itemsView: "notLoaded" }
    }, decodeThreadResume);
    if (resumed.lastTurnId !== turnId) return void 0;
    const record = this.#record(resumed.threadId, tools, turnId);
    this.#register(record);
    try {
      await this.#auditFeatures(client, record.threadId);
    } catch (error) {
      this.#threads.delete(record.threadId);
      throw error;
    }
    return record;
  }
  /**
   * Which Codex thread serves this transcript. Pi's latest clean pi-codex
   * message names a thread, a turn and a tool signature. The bridge continues
   * that thread only when the signature matches Pi's current tools and the
   * thread's latest turn is that turn; otherwise it starts a new thread and
   * replays the transcript, so Codex never holds turns Pi has dropped or calls
   * a tool Pi no longer has.
   */
  async #plan(client, model, messages, tools) {
    const boundary = findBoundary(messages);
    if (boundary !== void 0 && boundary.toolSignature === tools.signature) {
      const after = afterBoundary(messages, boundary);
      const record2 = this.#threads.get(boundary.threadId);
      if (record2 !== void 0) {
        if (boundary.stopReason === "toolUse" && record2.activeTurnId === boundary.turnId && record2.pending.length > 0) {
          return { record: record2, mode: "continue", input: after.input, answers: answerToolCalls(record2.pending, after.toolResults) };
        }
        if (boundary.stopReason === "stop" && record2.activeTurnId === null && record2.lastTurnId === boundary.turnId) {
          return { record: record2, mode: "turn", input: after.input };
        }
        this.#abandon(client, record2);
      } else if (boundary.stopReason === "stop") {
        const resumed = await this.#resumeThread(client, model, boundary.threadId, boundary.turnId, tools);
        if (resumed !== void 0) return { record: resumed, mode: "turn", input: after.input };
      }
    }
    const record = await this.#startThread(client, model, messages, tools);
    return { record, mode: "turn", input: replayInput(messages) };
  }
  // --- Streams -------------------------------------------------------------
  async #run(stream, model, context, options) {
    const output = {
      role: "assistant",
      content: [],
      api: API_ID,
      provider: PROVIDER_ID,
      model: model.id,
      usage: emptyUsage(),
      stopReason: "pending",
      timestamp: Date.now()
    };
    let record;
    let client;
    const signal = options?.signal;
    let rejectAborted;
    const aborted = new Promise((_, reject) => rejectAborted = reject);
    aborted.catch(() => void 0);
    const onAbort = () => {
      rejectAborted?.(new Error("codex-request-aborted"));
      if (client !== void 0 && record !== void 0) this.#interrupt(client, record);
    };
    signal?.addEventListener("abort", onAbort, { once: true });
    try {
      if (signal?.aborted) throw new Error("codex-request-aborted");
      const messages = collapseSystemMessages(context).messages;
      const tools = buildDynamicTools(getCurrentTools(messages));
      client = await Promise.race([this.#client ??= this.#open(), aborted]);
      const plan = await Promise.race([this.#plan(client, model, messages, tools), aborted]);
      record = plan.record;
      if (record.streaming) throw new Error(`codex-thread-busy thread=${record.threadId}`);
      record.streaming = true;
      record.lastUsed = Date.now();
      if (plan.mode === "continue") {
        const payload = { method: "item/tool/call", answers: plan.answers, steer: plan.input };
        const sent = await options?.onPayload?.(payload, model) ?? payload;
        for (const answer of sent.answers) client.respond(answer.requestId, answer.result);
        record.pending = [];
        if (sent.steer.length > 0) {
          await client.request("turn/steer", { threadId: record.threadId, expectedTurnId: record.activeTurnId, input: sent.steer });
        }
      } else {
        if (plan.input.length === 0) throw new Error("codex-turn-input-empty");
        const effort = codexEffort(model, options?.reasoning);
        const params = {
          threadId: record.threadId,
          input: plan.input,
          model: model.id,
          approvalPolicy: APPROVAL_POLICY,
          environments: [],
          ...effort === null ? {} : { effort }
        };
        const sent = await options?.onPayload?.(params, model) ?? params;
        const { turnId } = await client.requestDecoded("turn/start", sent, decodeTurnStart);
        record.activeTurnId = turnId;
        record.lastTurnId = turnId;
      }
      await options?.onResponse?.({ status: 200, headers: {} }, model);
      output.responseId = encodeResponseId(record.threadId, record.activeTurnId, tools.signature);
      if (signal?.aborted) throw new Error("codex-request-aborted");
      stream.push({ type: "start", partial: output });
      await this.#consume(stream, output, model, record, options);
    } catch (error) {
      if (client !== void 0 && record !== void 0 && record.activeTurnId !== null) this.#abandon(client, record);
      output.stopReason = signal?.aborted ? "aborted" : "error";
      output.errorMessage = error instanceof Error ? error.message : "codex-bridge-error";
      stream.push({ type: "error", reason: output.stopReason, error: output });
      stream.end();
    } finally {
      signal?.removeEventListener("abort", onAbort);
      if (record !== void 0) record.streaming = false;
    }
  }
  /** Read the thread's queue until the turn completes or Codex waits on a
   * tool call. Codex holds a turn on each `item/tool/call` until the bridge
   * answers it, so that request is what ends a tool batch. */
  async #consume(stream, output, model, record, options) {
    const textIndex = /* @__PURE__ */ new Map();
    const thinkingIndex = /* @__PURE__ */ new Map();
    const closeBlocks = () => {
      for (const index of thinkingIndex.values()) {
        const block = output.content[index];
        if (block.type === "thinking") stream.push({ type: "thinking_end", contentIndex: index, content: block.thinking, partial: output });
      }
      for (const index of textIndex.values()) {
        const block = output.content[index];
        if (block.type === "text") stream.push({ type: "text_end", contentIndex: index, content: block.text, partial: output });
      }
    };
    const appendText = (itemId, delta) => {
      let index = textIndex.get(itemId);
      if (index === void 0) {
        index = output.content.length;
        textIndex.set(itemId, index);
        output.content.push({ type: "text", text: "" });
        stream.push({ type: "text_start", contentIndex: index, partial: output });
      }
      const block = output.content[index];
      if (block.type !== "text") throw new Error("codex-text-state-invalid");
      block.text += delta;
      stream.push({ type: "text_delta", contentIndex: index, delta, partial: output });
    };
    const addToolCall = (requestId2, call) => {
      if (call.turnId !== record.activeTurnId) throw new Error(`codex-tool-call-turn-mismatch turn=${call.turnId}`);
      if (call.namespace !== null) throw new Error(`codex-tool-call-namespace-refused namespace=${call.namespace}`);
      const piToolName = record.tools.piNameByCodexName.get(call.tool);
      if (piToolName === void 0) throw new Error(`codex-tool-call-unknown tool=${call.tool}`);
      if (record.pending.some((pending) => pending.callId === call.callId)) throw new Error(`codex-tool-call-duplicate call=${call.callId}`);
      if (record.pending.length >= MAX_PENDING_CALLS) throw new Error(`codex-tool-calls-full limit=${MAX_PENDING_CALLS}`);
      record.pending.push({ requestId: requestId2, callId: call.callId, piToolName });
      const contentIndex = output.content.length;
      const toolCall = { type: "toolCall", id: call.callId, name: piToolName, arguments: call.arguments };
      output.content.push(toolCall);
      stream.push({ type: "toolcall_start", contentIndex, partial: output });
      stream.push({ type: "toolcall_end", contentIndex, toolCall, partial: output });
    };
    while (true) {
      const item = await record.queue.next();
      if (item.kind === "refusal") {
        if (item.turnId !== null && item.turnId !== record.activeTurnId) continue;
        throw item.error;
      }
      await options?.onProviderStreamEvent?.(item.raw, model);
      if (item.kind === "toolCall") {
        addToolCall(item.requestId, item.call);
        for (let next = record.queue.takeToolCall(); next !== void 0; next = record.queue.takeToolCall()) {
          await options?.onProviderStreamEvent?.(next.raw, model);
          addToolCall(next.requestId, next.call);
        }
        closeBlocks();
        output.stopReason = "toolUse";
        stream.push({ type: "done", reason: "toolUse", message: output });
        stream.end();
        return;
      }
      const event = item.event;
      if (event.turnId !== record.activeTurnId) continue;
      switch (event.type) {
        case "agentDelta":
          appendText(event.itemId, event.delta);
          break;
        case "agentMessageCompleted": {
          const index = textIndex.get(event.itemId);
          const shown = index === void 0 ? "" : output.content[index].text;
          if (event.text.length > shown.length && event.text.startsWith(shown)) appendText(event.itemId, event.text.slice(shown.length));
          break;
        }
        case "reasoningDelta": {
          let index = thinkingIndex.get(event.itemId);
          if (index === void 0) {
            index = output.content.length;
            thinkingIndex.set(event.itemId, index);
            output.content.push({ type: "thinking", thinking: "" });
            stream.push({ type: "thinking_start", contentIndex: index, partial: output });
          }
          const block = output.content[index];
          if (block.type !== "thinking") throw new Error("codex-thinking-state-invalid");
          block.thinking += event.delta;
          stream.push({ type: "thinking_delta", contentIndex: index, delta: event.delta, partial: output });
          break;
        }
        case "tokenUsage":
          output.usage.input += event.usage.input;
          output.usage.output += event.usage.output;
          output.usage.cacheRead += event.usage.cacheRead;
          output.usage.cacheWrite += event.usage.cacheWrite;
          output.usage.totalTokens += event.usage.total;
          break;
        case "turnCompleted":
          record.activeTurnId = null;
          if (event.status === "completed") {
            closeBlocks();
            output.stopReason = "stop";
            stream.push({ type: "done", reason: "stop", message: output });
            stream.end();
            return;
          }
          if (event.status === "interrupted") throw new Error(options?.signal?.aborted ? "codex-request-aborted" : "codex-turn-interrupted");
          throw new Error(`codex-turn-failed${event.error ? `
${event.error.split("\n", 1)[0]}` : ""}`);
        default:
          break;
      }
    }
  }
};

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
        const text2 = texts[index] ?? readText(path);
        if (text2.kind === "absent") return [];
        if (text2.kind === "unreadable") return [{ kind: "malformed", path, error: text2.error }];
        try {
          const parsed = JSON.parse(text2.text);
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
  const codexHome = resolveCodexHome();
  const bridge = new CodexBridge({ codexHome });
  globalState[OWNER] = bridge;
  let notice;
  let models = [];
  if (hasCodexLogin(codexHome)) {
    const discovered = await bridge.discoverModels();
    models = buildPiModels(discovered.models);
    notice = discovered.notice;
  }
  pi.registerProvider(piAi.createProvider({
    id: PROVIDER_ID,
    name: "Pi Codex",
    baseUrl: API_ID,
    auth: {
      apiKey: {
        name: "Codex CLI login",
        check: async () => hasCodexLogin(codexHome) ? { type: "api_key", source: "Codex CLI login" } : void 0,
        resolve: async () => hasCodexLogin(codexHome) ? { auth: {}, source: "Codex CLI login" } : void 0
      }
    },
    models,
    api: { stream: bridge.streamSimple, streamSimple: bridge.streamSimple }
  }));
  pi.on("session_start", (_event, ctx) => {
    if (notice === void 0) return;
    const text2 = `${notice}
Pi Codex could not list Codex models, so none are offered. Run /reload to try again.`;
    if (ctx.hasUI) ctx.ui.notify(text2, "warning");
    else process.stderr.write(`${text2}
`);
    notice = void 0;
  });
  pi.on("session_shutdown", async () => {
    await bridge.close();
    if (globalState[OWNER] === bridge) globalState[OWNER] = void 0;
  });
}
export {
  piCodexBridge as default
};
