import { pbkdf2Sync, createDecipheriv } from "node:crypto";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { copyFile, mkdtemp, rm } from "node:fs/promises";
import { homedir, platform, tmpdir } from "node:os";
import { join } from "node:path";
import { type PiExec, runHelper, withDeadline } from "./deadline.js";

export type CookieMap = Record<string, string>;

export interface BrowserCookieResult {
	browser: string;
	profile: string;
	cookies: CookieMap;
}

export interface ReadCookiesOptions {
	/** Runs sqlite3 and the keyring helpers. */
	pi: PiExec;
	preferredBrowser?: "auto" | "firefox" | "zen" | "chrome" | "chromium";
	profile?: string;
	hosts?: string[];
	cookieNames?: string[];
	requiredCookies?: string[];
	/** Deadline of each sqlite3 run; SQLITE_DEADLINE_MS when absent. */
	sqliteTimeoutMs?: number;
	/** Deadline of each keyring or DPAPI helper run; KEYRING_DEADLINE_MS when absent. */
	keyringTimeoutMs?: number;
}

/** Longest one sqlite3 run may take: it reads a local copy of the cookie database and waits on nothing. */
export const SQLITE_DEADLINE_MS = 4_000;
/** Longest one keyring or DPAPI helper run may take. The first macOS keychain read and a locked GNOME keyring wait for the
 * user to answer a prompt, and Windows starts PowerShell cold; a helper still running at this bound is killed. */
export const KEYRING_DEADLINE_MS = 60_000;
/** How long a browser's keyring secret is reused before the keyring is asked again. */
export const CREDENTIAL_CACHE_MS = 10 * 60_000;

/** The helpers of one cookie read: Pi's exec, the tool call's signal and each helper kind's deadline. */
interface HelperRun {
	pi: PiExec;
	signal: AbortSignal | undefined;
	sqliteTimeoutMs: number;
	keyringTimeoutMs: number;
}

/** Keyring secrets by browser, each kept CREDENTIAL_CACHE_MS and shared by every session in the Pi process. An expired entry
 * is replaced on the next read of its browser, and the map holds one entry per discovered browser at most. */
const credentials = new Map<string, { secret: string; expiresAt: number }>();

/** The secret `read` returns for `key`, from the cache while its entry is younger than CREDENTIAL_CACHE_MS. A read that
 * finds no secret is not kept, so the keyring is asked again next time. */
async function cachedSecret(key: string, read: () => Promise<string | null>): Promise<string | null> {
	const cached = credentials.get(key);
	if (cached && cached.expiresAt > Date.now()) return cached.secret;
	credentials.delete(key);
	const secret = await read();
	if (secret !== null) credentials.set(key, { secret, expiresAt: Date.now() + CREDENTIAL_CACHE_MS });
	return secret;
}

/** The trimmed stdout of a helper run under `timeoutMs`, or null when it fails or prints nothing. Its deadline's TimeoutError
 * or the tool call's cancellation is rethrown, so the read ends with its cause instead of trying the next browser. */
async function helperOutput(run: HelperRun, command: string, args: string[], timeoutMs: number): Promise<string | null> {
	return await withDeadline(run.signal, timeoutMs, command, async (deadline) => {
		try {
			return (await runHelper(run.pi, command, args, deadline)).trim() || null;
		} catch (error) {
			if (deadline.aborted) throw error;
			return null;
		}
	});
}

const DEFAULT_HOSTS = ["gemini.google.com", "accounts.google.com", "www.google.com", ".google.com", "google.com"];
const DEFAULT_COOKIE_NAMES = new Set([
	"__Secure-1PSID",
	"__Secure-1PSIDTS",
	"__Secure-1PSIDCC",
	"__Secure-1PAPISID",
	"__Secure-3PSID",
	"__Secure-3PSIDTS",
	"__Secure-3PAPISID",
	"NID",
	"AEC",
	"SOCS",
	"SID",
	"HSID",
	"SSID",
	"APISID",
	"SAPISID",
	"SIDCC",
]);

interface FirefoxBrowser {
	kind: "firefox";
	name: string;
	root: string;
}

interface ChromeBrowser {
	kind: "chrome";
	name: string;
	root: string;
	keychainService?: string;
	keychainAccount?: string;
	secretToolApp?: string;
	windowsLocalState?: string;
}

type BrowserConfig = FirefoxBrowser | ChromeBrowser;

function discoverBrowsers(): BrowserConfig[] {
	const list: BrowserConfig[] = [];
	const home = homedir();
	const ff = (name: string, base: string) => existsSync(join(home, base)) && list.push({ kind: "firefox", name, root: join(home, base) });
	ff("Firefox", ".mozilla/firefox");
	ff("Zen", ".zen");
	if (platform() === "darwin") ff("Firefox", "Library/Application Support/Firefox/Profiles");
	if (platform() === "win32") {
		const appdata = process.env.APPDATA;
		if (appdata) {
			const ffRoot = join(appdata, "Mozilla", "Firefox", "Profiles");
			if (existsSync(ffRoot)) list.push({ kind: "firefox", name: "Firefox", root: ffRoot });
			const zenRoot = join(appdata, "zen", "Profiles");
			if (existsSync(zenRoot)) list.push({ kind: "firefox", name: "Zen", root: zenRoot });
		}
	}
	const chrome = (name: string, base: string, opts: Omit<ChromeBrowser, "kind" | "name" | "root">) => {
		const root = join(home, base);
		if (existsSync(root)) list.push({ kind: "chrome", name, root, ...opts });
	};
	if (platform() === "linux") {
		chrome("Chromium", ".config/chromium", { secretToolApp: "chromium" });
		chrome("Chrome", ".config/google-chrome", { secretToolApp: "chrome" });
	} else if (platform() === "darwin") {
		chrome("Chrome", "Library/Application Support/Google/Chrome", { keychainService: "Chrome Safe Storage", keychainAccount: "Chrome" });
		chrome("Chromium", "Library/Application Support/Chromium", { keychainService: "Chromium Safe Storage", keychainAccount: "Chromium" });
	} else if (platform() === "win32") {
		const localApp = process.env.LOCALAPPDATA;
		if (localApp) {
			const chromeRoot = join(localApp, "Google", "Chrome", "User Data");
			if (existsSync(chromeRoot)) list.push({ kind: "chrome", name: "Chrome", root: chromeRoot, windowsLocalState: join(chromeRoot, "Local State") });
			const chromiumRoot = join(localApp, "Chromium", "User Data");
			if (existsSync(chromiumRoot)) list.push({ kind: "chrome", name: "Chromium", root: chromiumRoot, windowsLocalState: join(chromiumRoot, "Local State") });
			const edgeRoot = join(localApp, "Microsoft", "Edge", "User Data");
			if (existsSync(edgeRoot)) list.push({ kind: "chrome", name: "Edge", root: edgeRoot, windowsLocalState: join(edgeRoot, "Local State") });
		}
	}
	return list;
}

function pickBrowser(list: BrowserConfig[], preferred: ReadCookiesOptions["preferredBrowser"]): BrowserConfig[] {
	if (!preferred || preferred === "auto") return list;
	const filtered = list.filter((b) => b.name.toLowerCase() === preferred);
	return filtered.length ? filtered : list;
}

function findFirefoxProfiles(root: string): string[] {
	const entries = readdirSync(root, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => join(root, e.name));
	const withCookies = entries.filter((dir) => existsSync(join(dir, "cookies.sqlite")));
	return withCookies.sort((a, b) => statSync(join(b, "cookies.sqlite")).mtimeMs - statSync(join(a, "cookies.sqlite")).mtimeMs);
}

function findChromeProfiles(root: string, requestedProfile?: string): string[] {
	if (requestedProfile) {
		const dir = join(root, requestedProfile);
		return existsSync(join(dir, "Cookies")) ? [dir] : [];
	}
	const candidates = ["Default", ...readdirSync(root, { withFileTypes: true }).filter((e) => e.isDirectory() && /^Profile\b/.test(e.name)).map((e) => e.name)];
	return candidates.map((name) => join(root, name)).filter((dir) => existsSync(join(dir, "Cookies")));
}

/** Runs `read` on a copy of the cookie database `src`, in a temporary directory removed when `read` settles. */
async function withDbCopy<T>(src: string, read: (tempDb: string) => Promise<T>): Promise<T> {
	const tempDir = await mkdtemp(join(tmpdir(), "pi-web-cookies-"));
	try {
		const tempDb = join(tempDir, "cookies.sqlite");
		await copyFile(src, tempDb);
		for (const suffix of ["-wal", "-shm"]) {
			if (existsSync(src + suffix)) await copyFile(src + suffix, tempDb + suffix).catch(() => undefined);
		}
		return await read(tempDb);
	} finally {
		await rm(tempDir, { recursive: true, force: true });
	}
}

function runSqlite3(run: HelperRun, dbPath: string, query: string): Promise<string | null> {
	return helperOutput(run, "sqlite3", ["-readonly", "-batch", "-cmd", ".mode list", "-cmd", '.separator "\\x01"', dbPath, query], run.sqliteTimeoutMs);
}

function decodeFirefoxRows(output: string | null): Array<{ name: string; value: string; host: string }> {
	if (!output) return [];
	const rows: Array<{ name: string; value: string; host: string }> = [];
	for (const line of output.split(/\r?\n/)) {
		if (!line) continue;
		const parts = line.split("\u0001");
		if (parts.length < 3) continue;
		rows.push({ name: parts[0]!, value: parts[1]!, host: parts[2]! });
	}
	return rows;
}

async function readFirefoxProfile(run: HelperRun, profileDir: string, hosts: string[], names: Set<string>): Promise<CookieMap | null> {
	const dbPath = join(profileDir, "cookies.sqlite");
	if (!existsSync(dbPath)) return null;
	return await withDbCopy(dbPath, async (tempDb) => {
		const hostClause = hosts.map((h) => `host LIKE '%${h.replace(/'/g, "''")}%'`).join(" OR ");
		const sql = `SELECT name, value, host FROM moz_cookies WHERE ${hostClause};`;
		const out = await runSqlite3(run, tempDb, sql);
		const rows = decodeFirefoxRows(out);
		const cookies: CookieMap = {};
		for (const row of rows) {
			if (!names.has(row.name) || cookies[row.name]) continue;
			cookies[row.name] = row.value;
		}
		return cookies;
	});
}

function decryptChromeCookieValue(encrypted: Buffer, key: Buffer): string | null {
	if (encrypted.length < 3) return null;
	const prefix = encrypted.subarray(0, 3).toString("utf8");
	if (prefix !== "v10" && prefix !== "v11") return null;
	const iv = Buffer.alloc(16, 0x20);
	try {
		const decipher = createDecipheriv("aes-128-cbc", key, iv);
		const decrypted = Buffer.concat([decipher.update(encrypted.subarray(3)), decipher.final()]);
		return decrypted.toString("utf8");
	} catch {
		return null;
	}
}

async function decryptWindowsDpapi(run: HelperRun, encrypted: Buffer): Promise<Buffer | null> {
	const base64 = encrypted.toString("base64");
	const script = `[Reflection.Assembly]::LoadWithPartialName('System.Security') | Out-Null; $b=[Convert]::FromBase64String('${base64}'); $u=[System.Security.Cryptography.ProtectedData]::Unprotect($b,$null,'CurrentUser'); [Convert]::ToBase64String($u)`;
	const out = await helperOutput(run, "powershell", ["-NoProfile", "-NonInteractive", "-Command", script], run.keyringTimeoutMs);
	return out === null ? null : Buffer.from(out, "base64");
}

async function loadWindowsChromeMasterKey(run: HelperRun, localStatePath: string): Promise<Buffer | null> {
	if (!existsSync(localStatePath)) return null;
	let encryptedKey: Buffer;
	try {
		const json = JSON.parse(readFileSync(localStatePath, "utf8"));
		const encryptedKeyB64 = json?.os_crypt?.encrypted_key;
		if (typeof encryptedKeyB64 !== "string") return null;
		encryptedKey = Buffer.from(encryptedKeyB64, "base64");
	} catch {
		return null;
	}
	if (encryptedKey.subarray(0, 5).toString("utf8") !== "DPAPI") return null;
	const key = await cachedSecret(`dpapi:${localStatePath}`, async () => (await decryptWindowsDpapi(run, encryptedKey.subarray(5)))?.toString("base64") ?? null);
	return key === null ? null : Buffer.from(key, "base64");
}

async function decryptWindowsChromeCookieValue(run: HelperRun, encrypted: Buffer, masterKey: Buffer): Promise<string | null> {
	if (encrypted.length < 15) return null;
	const prefix = encrypted.subarray(0, 3).toString("utf8");
	if (prefix === "v10") {
		const iv = encrypted.subarray(3, 15);
		const body = encrypted.subarray(15, encrypted.length - 16);
		const tag = encrypted.subarray(encrypted.length - 16);
		try {
			const decipher = createDecipheriv("aes-256-gcm", masterKey, iv);
			decipher.setAuthTag(tag);
			const decrypted = Buffer.concat([decipher.update(body), decipher.final()]);
			return decrypted.toString("utf8");
		} catch {
			return null;
		}
	}
	const plain = await decryptWindowsDpapi(run, encrypted);
	return plain ? plain.toString("utf8") : null;
}

async function readChromeMetaVersion(run: HelperRun, dbPath: string): Promise<number> {
	const out = await runSqlite3(run, dbPath, "SELECT value FROM meta WHERE key='version';");
	const num = Number((out ?? "").trim().split(/\x01/).pop());
	return Number.isFinite(num) ? num : 0;
}

interface ChromeRow { host_key: string; name: string; encrypted_value: Buffer; value: string }

async function readChromeRows(run: HelperRun, dbPath: string, hosts: string[]): Promise<ChromeRow[]> {
	const hostClause = hosts.map((h) => `host_key LIKE '%${h.replace(/'/g, "''")}%'`).join(" OR ");
	const out = await runSqlite3(run, dbPath, `SELECT host_key, name, hex(encrypted_value), value FROM cookies WHERE ${hostClause};`);
	if (!out) return [];
	const rows: ChromeRow[] = [];
	for (const line of out.split(/\r?\n/)) {
		if (!line) continue;
		const parts = line.split("\u0001");
		if (parts.length < 4) continue;
		const encrypted = Buffer.from(parts[2] ?? "", "hex");
		rows.push({ host_key: parts[0]!, name: parts[1]!, encrypted_value: encrypted, value: parts[3] ?? "" });
	}
	return rows;
}

/** The password the browser encrypts its cookies with: its keyring entry, or Chrome's built-in default when it has none. */
async function chromePassword(run: HelperRun, browser: ChromeBrowser): Promise<string> {
	const key = `${browser.name}:${browser.root}`;
	if (browser.secretToolApp) {
		const app = browser.secretToolApp;
		return await cachedSecret(key, () => helperOutput(run, "secret-tool", ["lookup", "application", app], run.keyringTimeoutMs)) ?? "peanuts";
	}
	if (browser.keychainService && browser.keychainAccount) {
		const { keychainService, keychainAccount } = browser;
		return await cachedSecret(key, () => helperOutput(run, "security", ["find-generic-password", "-s", keychainService, "-a", keychainAccount, "-w"], run.keyringTimeoutMs)) ?? "peanuts";
	}
	return "peanuts";
}

async function readChromeProfile(run: HelperRun, browser: ChromeBrowser, profileDir: string, hosts: string[], names: Set<string>): Promise<CookieMap | null> {
	const dbPath = join(profileDir, "Cookies");
	const dbCandidates = [dbPath, join(profileDir, "Network", "Cookies")];
	const foundDb = dbCandidates.find((p) => existsSync(p));
	if (!foundDb) return null;
	const isWindows = platform() === "win32";
	let windowsMasterKey: Buffer | null = null;
	let linuxMacKey: Buffer | null = null;
	if (isWindows) {
		windowsMasterKey = browser.windowsLocalState ? await loadWindowsChromeMasterKey(run, browser.windowsLocalState) : null;
		if (!windowsMasterKey) return null;
	} else {
		const password = await chromePassword(run, browser);
		const iters = platform() === "darwin" ? 1003 : 1;
		linuxMacKey = pbkdf2Sync(password, "saltysalt", iters, 16, "sha1");
	}
	return await withDbCopy(foundDb, async (tempDb) => {
		const metaVersion = await readChromeMetaVersion(run, tempDb);
		const stripHash = metaVersion >= 24;
		const rows = await readChromeRows(run, tempDb, hosts);
		const cookies: CookieMap = {};
		for (const row of rows) {
			if (!names.has(row.name) || cookies[row.name]) continue;
			let value: string | null = row.value && row.value.length > 0 ? row.value : null;
			if (!value && row.encrypted_value.length) {
				value = isWindows && windowsMasterKey
					? await decryptWindowsChromeCookieValue(run, row.encrypted_value, windowsMasterKey)
					: linuxMacKey ? decryptChromeCookieValue(row.encrypted_value, linuxMacKey) : null;
			}
			if (value && stripHash && value.length >= 32) value = value.slice(32);
			if (value) cookies[row.name] = value;
		}
		return cookies;
	});
}

/** The first browser profile holding the required cookies, or null when none does. Each sqlite3 run ends at `sqliteTimeoutMs`
 * or SQLITE_DEADLINE_MS, each keyring or DPAPI helper at `keyringTimeoutMs` or KEYRING_DEADLINE_MS; a helper's TimeoutError
 * or `signal`'s reason rejects the read rather than trying the next browser. */
export async function readBrowserCookies(options: ReadCookiesOptions, signal?: AbortSignal): Promise<BrowserCookieResult | null> {
	const browsers = pickBrowser(discoverBrowsers(), options.preferredBrowser);
	const hosts = options.hosts && options.hosts.length ? options.hosts : DEFAULT_HOSTS;
	const names = new Set(options.cookieNames && options.cookieNames.length ? options.cookieNames : Array.from(DEFAULT_COOKIE_NAMES));
	const run: HelperRun = { pi: options.pi, signal, sqliteTimeoutMs: options.sqliteTimeoutMs ?? SQLITE_DEADLINE_MS, keyringTimeoutMs: options.keyringTimeoutMs ?? KEYRING_DEADLINE_MS };
	for (const browser of browsers) {
		try {
			if (browser.kind === "firefox") {
				const profiles = options.profile ? [join(browser.root, options.profile)] : findFirefoxProfiles(browser.root);
				for (const profileDir of profiles) {
					const cookies = await readFirefoxProfile(run, profileDir, hosts, names);
					if (!cookies) continue;
					if (options.requiredCookies?.length && !options.requiredCookies.every((n) => cookies[n])) continue;
					return { browser: browser.name, profile: profileDir, cookies };
				}
			} else {
				const profiles = findChromeProfiles(browser.root, options.profile);
				for (const profileDir of profiles) {
					const cookies = await readChromeProfile(run, browser, profileDir, hosts, names);
					if (!cookies) continue;
					if (options.requiredCookies?.length && !options.requiredCookies.every((n) => cookies[n])) continue;
					return { browser: browser.name, profile: profileDir, cookies };
				}
			}
		} catch (error) {
			// helperOutput rethrows only a helper's deadline or the cancellation; any other failure moves on to the next browser.
			if (signal?.aborted || (error instanceof DOMException && error.name === "TimeoutError")) throw error;
		}
	}
	return null;
}

export function buildCookieHeader(cookies: CookieMap): string {
	return Object.entries(cookies).filter(([, v]) => typeof v === "string" && v.length > 0).map(([k, v]) => `${k}=${v}`).join("; ");
}
