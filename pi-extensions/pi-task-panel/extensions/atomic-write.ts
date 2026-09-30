import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

/**
 * Replaces `file` with `text` whole: the text goes to a temporary file beside
 * it, which is then renamed over it. A reader sees the old file or the new
 * one, never a partial write, and a failed write leaves the old file intact.
 * The temporary name is fixed per process, so a leftover from a failed write
 * is overwritten by that process's next write instead of piling up; callers
 * must not run two writes to the same file at once.
 */
export async function writeFileAtomic(file: string, text: string): Promise<void> {
	await mkdir(dirname(file), { recursive: true, mode: 0o700 });
	const temporary = `${file}.tmp-${process.pid}`;
	await writeFile(temporary, text, { encoding: "utf8", mode: 0o600 });
	await rename(temporary, file);
}
