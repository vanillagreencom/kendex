const CREDENTIAL_NAME = /(?:AUTH|CREDENTIAL|PASSWORD|PASSWD|PRIVATE_KEY|ACCESS_KEY|API_KEY|SECRET|TOKEN)/i;

/** Build the Codex child environment without ambient alternate credentials. */
export function codexChildEnvironment(
	codexHome: string,
	env: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
	const child: NodeJS.ProcessEnv = {};
	for (const [name, value] of Object.entries(env)) {
		if (name !== "CODEX_HOME" && CREDENTIAL_NAME.test(name)) continue;
		child[name] = value;
	}
	child.CODEX_HOME = codexHome;
	return child;
}
