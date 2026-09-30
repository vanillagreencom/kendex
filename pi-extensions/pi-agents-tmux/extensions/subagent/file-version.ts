import type * as fs from "node:fs";

/**
 * A file's version: device, inode, byte size and modification time. A file
 * replaced by atomic rename is a new inode and so a new version; an append
 * moves the size and the modification time.
 */
export function fileVersion(stat: fs.Stats, size = stat.size): string {
	return `${stat.dev}:${stat.ino}:${size}:${stat.mtimeMs}`;
}
