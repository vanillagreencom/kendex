import { execFileSync } from "node:child_process";
import { pbkdf2Sync, createDecipheriv } from "node:crypto";
import { copyFileSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { homedir, platform, tmpdir } from "node:os";
import { join } from "node:path";

export type CookieMap = Record<string, string>;

export interface BrowserCookieResult {
	browser: string;
	profile: string;
	cookies: CookieMap;
}

export interface ReadCookiesOptions {
	preferredBrowser?: "auto" | "firefox" | "zen" | "chrome" | "chromium";
	profile?: string;
	hosts?: string[];
	cookieNames?: string[];
	requiredCookies?: string[];
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

function copyDb(src: string): { tempDir: string; tempDb: string } {
	const tempDir = mkdtempSync(join(tmpdir(), "pi-web-cookies-"));
	const tempDb = join(tempDir, "cookies.sqlite");
	copyFileSync(src, tempDb);
	for (const suffix of ["-wal", "-shm"]) {
		if (existsSync(src + suffix)) try { copyFileSync(src + suffix, tempDb + suffix); } catch { /* ignore */ }
	}
	return { tempDir, tempDb };
}

function runSqlite3(dbPath: string, query: string): string | null {
	try {
		return execFileSync("sqlite3", ["-readonly", "-batch", "-cmd", ".mode list", "-cmd", '.separator "\\x01"', dbPath, query], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
	} catch {
		return null;
	}
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

function readFirefoxProfile(profileDir: string, hosts: string[], names: Set<string>): CookieMap | null {
	const dbPath = join(profileDir, "cookies.sqlite");
	if (!existsSync(dbPath)) return null;
	const { tempDir, tempDb } = copyDb(dbPath);
	try {
		const hostClause = hosts.map((h) => `host LIKE '%${h.replace(/'/g, "''")}%'`).join(" OR ");
		const sql = `SELECT name, value, host FROM moz_cookies WHERE ${hostClause};`;
		const out = runSqlite3(tempDb, sql);
		const rows = decodeFirefoxRows(out);
		const cookies: CookieMap = {};
		for (const row of rows) {
			if (!names.has(row.name) || cookies[row.name]) continue;
			cookies[row.name] = row.value;
		}
		return cookies;
	} finally {
		rmSync(tempDir, { recursive: true, force: true });
	}
}

function readSecretTool(app: string): string | null {
	try {
		const out = execFileSync("secret-tool", ["lookup", "application", app], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
		return out || null;
	} catch {
		return null;
	}
}

function readMacKeychain(service: string, account: string): string | null {
	try {
		const out = execFileSync("security", ["find-generic-password", "-s", service, "-a", account, "-w"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
		return out || null;
	} catch {
		return null;
	}
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

function decryptWindowsDpapi(encrypted: Buffer): Buffer | null {
	try {
		const base64 = encrypted.toString("base64");
		const script = `[Reflection.Assembly]::LoadWithPartialName('System.Security') | Out-Null; $b=[Convert]::FromBase64String('${base64}'); $u=[System.Security.Cryptography.ProtectedData]::Unprotect($b,$null,'CurrentUser'); [Convert]::ToBase64String($u)`;
		const out = execFileSync("powershell", ["-NoProfile", "-NonInteractive", "-Command", script], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
		return Buffer.from(out, "base64");
	} catch {
		return null;
	}
}

function loadWindowsChromeMasterKey(localStatePath: string): Buffer | null {
	if (!existsSync(localStatePath)) return null;
	try {
		const json = JSON.parse(readFileSync(localStatePath, "utf8"));
		const encryptedKeyB64 = json?.os_crypt?.encrypted_key;
		if (typeof encryptedKeyB64 !== "string") return null;
		const encryptedKey = Buffer.from(encryptedKeyB64, "base64");
		if (encryptedKey.subarray(0, 5).toString("utf8") !== "DPAPI") return null;
		return decryptWindowsDpapi(encryptedKey.subarray(5));
	} catch {
		return null;
	}
}

function decryptWindowsChromeCookieValue(encrypted: Buffer, masterKey: Buffer): string | null {
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
	const plain = decryptWindowsDpapi(encrypted);
	return plain ? plain.toString("utf8") : null;
}

function readChromeMetaVersion(dbPath: string): number {
	const out = runSqlite3(dbPath, "SELECT value FROM meta WHERE key='version';");
	const num = Number((out ?? "").trim().split(/\x01/).pop());
	return Number.isFinite(num) ? num : 0;
}

interface ChromeRow { host_key: string; name: string; encrypted_value: Buffer; value: string }

function readChromeRows(dbPath: string, hosts: string[]): ChromeRow[] {
	const hostClause = hosts.map((h) => `host_key LIKE '%${h.replace(/'/g, "''")}%'`).join(" OR ");
	const out = runSqlite3(dbPath, `SELECT host_key, name, hex(encrypted_value), value FROM cookies WHERE ${hostClause};`);
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

function readChromeProfile(browser: ChromeBrowser, profileDir: string, hosts: string[], names: Set<string>): CookieMap | null {
	const dbPath = join(profileDir, "Cookies");
	const dbCandidates = [dbPath, join(profileDir, "Network", "Cookies")];
	const foundDb = dbCandidates.find((p) => existsSync(p));
	if (!foundDb) return null;
	const isWindows = platform() === "win32";
	let windowsMasterKey: Buffer | null = null;
	let linuxMacKey: Buffer | null = null;
	if (isWindows) {
		windowsMasterKey = browser.windowsLocalState ? loadWindowsChromeMasterKey(browser.windowsLocalState) : null;
		if (!windowsMasterKey) return null;
	} else {
		const password = browser.secretToolApp
			? readSecretTool(browser.secretToolApp) ?? "peanuts"
			: browser.keychainService && browser.keychainAccount
				? readMacKeychain(browser.keychainService, browser.keychainAccount) ?? "peanuts"
				: "peanuts";
		const iters = platform() === "darwin" ? 1003 : 1;
		linuxMacKey = pbkdf2Sync(password, "saltysalt", iters, 16, "sha1");
	}
	const { tempDir, tempDb } = copyDb(foundDb);
	try {
		const metaVersion = readChromeMetaVersion(tempDb);
		const stripHash = metaVersion >= 24;
		const rows = readChromeRows(tempDb, hosts);
		const cookies: CookieMap = {};
		for (const row of rows) {
			if (!names.has(row.name) || cookies[row.name]) continue;
			let value: string | null = row.value && row.value.length > 0 ? row.value : null;
			if (!value && row.encrypted_value.length) {
				value = isWindows && windowsMasterKey
					? decryptWindowsChromeCookieValue(row.encrypted_value, windowsMasterKey)
					: linuxMacKey ? decryptChromeCookieValue(row.encrypted_value, linuxMacKey) : null;
			}
			if (value && stripHash && value.length >= 32) value = value.slice(32);
			if (value) cookies[row.name] = value;
		}
		return cookies;
	} finally {
		rmSync(tempDir, { recursive: true, force: true });
	}
}

export async function readBrowserCookies(options: ReadCookiesOptions = {}): Promise<BrowserCookieResult | null> {
	const browsers = pickBrowser(discoverBrowsers(), options.preferredBrowser);
	const hosts = options.hosts && options.hosts.length ? options.hosts : DEFAULT_HOSTS;
	const names = new Set(options.cookieNames && options.cookieNames.length ? options.cookieNames : Array.from(DEFAULT_COOKIE_NAMES));
	for (const browser of browsers) {
		try {
			if (browser.kind === "firefox") {
				const profiles = options.profile ? [join(browser.root, options.profile)] : findFirefoxProfiles(browser.root);
				for (const profileDir of profiles) {
					const cookies = readFirefoxProfile(profileDir, hosts, names);
					if (!cookies) continue;
					if (options.requiredCookies?.length && !options.requiredCookies.every((n) => cookies[n])) continue;
					return { browser: browser.name, profile: profileDir, cookies };
				}
			} else {
				const profiles = findChromeProfiles(browser.root, options.profile);
				for (const profileDir of profiles) {
					const cookies = readChromeProfile(browser, profileDir, hosts, names);
					if (!cookies) continue;
					if (options.requiredCookies?.length && !options.requiredCookies.every((n) => cookies[n])) continue;
					return { browser: browser.name, profile: profileDir, cookies };
				}
			}
		} catch {
			// continue to next browser
		}
	}
	return null;
}

export function buildCookieHeader(cookies: CookieMap): string {
	return Object.entries(cookies).filter(([, v]) => typeof v === "string" && v.length > 0).map(([k, v]) => `${k}=${v}`).join("; ");
}
