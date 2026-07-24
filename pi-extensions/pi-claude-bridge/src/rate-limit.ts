export const RATE_LIMIT_AUTO_RESUME_EVENT = "vstack:rate-limit";
export const RATE_LIMIT_TOKEN = "\x1b[31m[rate-limit]\x1b[39m";

export function isExtraUsageRequiredMessage(value: unknown): boolean {
	let text: string;
	if (typeof value === "string") text = value;
	else if (value instanceof Error) text = value.message;
	else {
		try { text = JSON.stringify(value ?? ""); }
		catch { text = String(value); }
	}
	return /extra[-\s]?usage|overage|extra usage billing|extra usage credits|1M context/i.test(text);
}

export function uniqueNonEmptyLines(values: unknown[]): string[] {
	const seen = new Set<string>();
	const out: string[] = [];
	for (const value of values) {
		const text = typeof value === "string" ? value.trim() : value == null ? "" : String(value).trim();
		if (!text || seen.has(text)) continue;
		seen.add(text);
		out.push(text);
	}
	return out;
}

export function formatResetTimestamp(value: unknown): string {
	const parsed = typeof value === "number" ? value : typeof value === "string" ? Date.parse(value) : Number.NaN;
	if (!Number.isFinite(parsed)) return "unknown";
	return new Date(parsed).toLocaleString(undefined, {
		day: "numeric",
		hour: "numeric",
		minute: "2-digit",
		month: "short",
		second: "2-digit",
		timeZoneName: "short",
		year: "numeric",
	});
}

export const ALLOWED_RATE_LIMIT_WARNING_UTILIZATION_THRESHOLD = 80;

export function normalizeRateLimitUtilization(value: unknown): number | undefined {
	if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return undefined;
	if (value === 0) return 0;
	// Claude SDK payloads have appeared as both fractions and percentages.
	// Exact 1 is unit-ambiguous (1% vs 100%), so do not use it for allowed-warning copy.
	if (value > 0 && value < 1) return value * 100;
	if (value > 1 && value <= 100) return value;
	return undefined;
}

function rateLimitTypeLabel(value: unknown): string {
	const text = typeof value === "string" ? value.trim() : "";
	return text || "unknown";
}

export function formatAllowedRateLimitWarning(info: { status?: unknown; utilization?: unknown; rateLimitType?: unknown } | null | undefined): string | undefined {
	if (info?.status !== "allowed_warning") return undefined;
	const utilization = normalizeRateLimitUtilization(info.utilization);
	if (utilization === undefined || utilization < ALLOWED_RATE_LIMIT_WARNING_UTILIZATION_THRESHOLD) return undefined;
	return `Claude rate limit warning: nearing ${rateLimitTypeLabel(info.rateLimitType)} limit; check Claude Code /usage for exact utilization.`;
}
