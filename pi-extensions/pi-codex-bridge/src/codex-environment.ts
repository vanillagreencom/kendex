// The launch changes the Codex home, so the child receives only the inherited
// values it needs to run: the executable search path and user home, locale,
// the temporary directory, and proxy and CA settings. Every other variable,
// any credential among them, stays in the Pi process.
const INHERITED = new Set([
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
	"CURL_CA_BUNDLE",
]);

function inherited(name: string): boolean {
	return INHERITED.has(name) || name.startsWith("LC_");
}

/** The Codex child environment: the allowlisted inherited values plus the
 * exact resolved `CODEX_HOME`. */
export function codexChildEnvironment(codexHome: string, env: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
	const child: NodeJS.ProcessEnv = {};
	for (const [name, value] of Object.entries(env)) {
		if (value !== undefined && inherited(name)) child[name] = value;
	}
	child.CODEX_HOME = codexHome;
	return child;
}
