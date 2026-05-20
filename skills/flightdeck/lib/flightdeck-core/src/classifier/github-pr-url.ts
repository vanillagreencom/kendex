export interface GithubPullUrlMatch {
	url: string;
	number: number;
}

export const GITHUB_PULL_URL_RE = /https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/([0-9]+)(?:[/?#][^\s<>)\]]*)?/i;

// Adapter message_end text is trusted only as a completion sentinel when the
// child follows the Flightdeck contract: PR URL as the final non-empty line.
export const FINAL_GITHUB_PULL_URL_PATTERN = /(?:^|\r?\n)[^\r\n]*https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[0-9]+(?:[/?#][^\s<>)\]]*)?>?[.!]?\s*$/i;

export function extractFinalGithubPullUrl(text: string): GithubPullUrlMatch | null {
	const normalized = text.replace(/\s+$/u, "");
	if (!normalized) return null;
	const lines = normalized.split(/\r?\n/u);
	let last = "";
	for (let i = lines.length - 1; i >= 0; i -= 1) {
		const candidate = lines[i]?.trim() ?? "";
		if (candidate) { last = candidate; break; }
	}
	if (!last) return null;
	const match = last.match(GITHUB_PULL_URL_RE);
	if (!match) return null;
	const rawNumber = Number.parseInt(match[1] ?? "", 10);
	if (!Number.isFinite(rawNumber) || rawNumber <= 0) return null;
	return { number: rawNumber, url: match[0] ?? "" };
}
