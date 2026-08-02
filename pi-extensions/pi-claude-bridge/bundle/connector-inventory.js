// src/connector-inventory.ts
var CONNECTOR_NS_PREFIX = "mcp__claude_ai_";
var DEFAULT_API_BASE = "https://api.anthropic.com";
var DEFAULT_PROXY_BASE = "https://mcp-proxy.anthropic.com/v1/mcp";
var OAUTH_BETA_HEADER = "oauth-2025-04-20";
function connectorServerName(connectorName) {
  return `claude.ai ${connectorName.trim()}`;
}
function connectorProxyUrl(installedServerId, proxyBase = DEFAULT_PROXY_BASE) {
  return `${trimTrailingSlashes(proxyBase)}/${encodeURIComponent(installedServerId)}`;
}
function connectorServerNamespace(connectorName) {
  return `${CONNECTOR_NS_PREFIX}${connectorName.trim().replace(/\s+/g, "_")}__`;
}
function credentialCandidatePaths(env = process.env) {
  const roots = [];
  const configDir = env.CLAUDE_CONFIG_DIR?.trim();
  if (configDir) {
    roots.push(configDir);
  } else {
    const home = env.HOME?.trim();
    if (home) roots.push(`${home}/.claude`, home);
  }
  const seen = /* @__PURE__ */ new Set();
  const paths = [];
  for (const root of roots) {
    for (const name of [".credentials.json", ".claude.json"]) {
      const p = `${root}/${name}`;
      if (!seen.has(p)) {
        seen.add(p);
        paths.push(p);
      }
    }
  }
  return paths;
}
function resolveClaudeOAuth(readFile, env = process.env) {
  let accessToken;
  let organizationUuid;
  for (const path of credentialCandidatePaths(env)) {
    const raw = readFile(path);
    if (!raw) continue;
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch {
      continue;
    }
    accessToken ??= nonEmptyString(parsed?.claudeAiOauth?.accessToken);
    organizationUuid ??= nonEmptyString(parsed?.oauthAccount?.organizationUuid);
    if (accessToken && organizationUuid) break;
  }
  if (!accessToken || !organizationUuid) return void 0;
  return { accessToken, organizationUuid };
}
function nonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : void 0;
}
function connectorsListUrl(organizationUuid, apiBase = DEFAULT_API_BASE) {
  return `${trimTrailingSlashes(apiBase)}/api/oauth/organizations/${encodeURIComponent(organizationUuid)}/mcp/connectors/list`;
}
function trimTrailingSlashes(value) {
  let end = value.length;
  while (end > 0 && value.charCodeAt(end - 1) === 47) end--;
  return value.slice(0, end);
}
async function listAccountConnectors(deps) {
  const { credentials, apiBase, signal } = deps;
  const fetchImpl = deps.fetchImpl ?? fetch;
  const url = connectorsListUrl(credentials.organizationUuid, apiBase);
  const fail = (reason) => ({ ok: false, complete: false, reason: redactSecret(reason, credentials.accessToken) });
  let response;
  try {
    response = await fetchImpl(url, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${credentials.accessToken}`,
        "anthropic-beta": OAUTH_BETA_HEADER,
        "Content-Type": "application/json"
      },
      body: "{}",
      signal
    });
  } catch (error) {
    return fail(`connector list request failed: ${errorText(error)}`);
  }
  let bodyText;
  try {
    bodyText = await response.text();
  } catch (error) {
    return fail(`connector list response unreadable: ${errorText(error)}`);
  }
  if (!response.ok) {
    return fail(`connector list returned HTTP ${response.status}${apiErrorSuffix(bodyText)}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(bodyText);
  } catch {
    return fail("connector list returned a non-JSON body");
  }
  if (!Array.isArray(parsed?.results)) {
    return fail("connector list response had no results array");
  }
  const connectors = [];
  for (const raw of parsed.results) {
    const entry = raw;
    const name = nonEmptyString(entry?.name);
    if (!name) {
      return fail("connector list contained an entry with no name");
    }
    connectors.push({
      name,
      installedServerId: nonEmptyString(entry?.installedServerId),
      directoryUuid: nonEmptyString(entry?.directoryUuid),
      installState: nonEmptyString(entry?.installState),
      description: nonEmptyString(entry?.description),
      isAuthless: typeof entry?.isAuthless === "boolean" ? entry.isAuthless : void 0
    });
  }
  return { ok: true, complete: true, connectors };
}
function apiErrorSuffix(bodyText) {
  try {
    const message = JSON.parse(bodyText)?.error?.message;
    return typeof message === "string" && message.trim() ? ` (${message.trim()})` : "";
  } catch {
    return "";
  }
}
function redactSecret(text, secret) {
  if (!secret || secret.length < 8) return text;
  let out = text;
  for (const form of /* @__PURE__ */ new Set([secret, encodeURIComponent(secret)])) {
    out = out.split(form).join("[redacted]");
  }
  return out;
}
function errorText(error) {
  return error instanceof Error ? error.message : String(error);
}
export {
  connectorProxyUrl,
  connectorServerName,
  connectorServerNamespace,
  connectorsListUrl,
  credentialCandidatePaths,
  listAccountConnectors,
  resolveClaudeOAuth
};
