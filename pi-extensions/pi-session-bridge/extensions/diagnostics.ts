export function stringifyError(error: unknown): string {
	const code = error && typeof error === "object" && "code" in error ? String(error.code) : error instanceof Error ? error.name : typeof error;
	const path = error && typeof error === "object" && "path" in error && typeof error.path === "string" ? ` path=${error.path}` : "";
	const explanation = error instanceof Error ? error.message : String(error);
	return `error_code=${code}${path}\n${explanation}`;
}
