import type { MonitorDetailEntry } from "../types.js";

function entryBytes(entry: MonitorDetailEntry): number {
	return entry.items?.reduce((sum, item) => sum + Buffer.byteLength(item.text), 0) ?? 0;
}

/** One popup keeps at most 32 loaded traces and 4 MiB of trace text. */
export class MonitorDetailCache extends Map<string, MonitorDetailEntry> {
	override set(key: string, entry: MonitorDetailEntry): this {
		if (entryBytes(entry) > 4 * 1024 * 1024) {
			entry = { error: "Trace exceeds the popup's 4 MiB cache limit. Open its transcript file." };
		}
		super.delete(key);
		super.set(key, entry);
		let bytes = [...this.values()].reduce((sum, value) => sum + entryBytes(value), 0);
		while (this.size > 32 || bytes > 4 * 1024 * 1024) {
			const first = this.keys().next().value!;
			bytes -= entryBytes(this.get(first)!);
			super.delete(first);
		}
		return this;
	}
}
