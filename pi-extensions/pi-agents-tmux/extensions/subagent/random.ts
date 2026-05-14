import { randomBytes, randomInt } from "node:crypto";

export function randomHex(bytes: number = 8): string {
	return randomBytes(Math.max(1, Math.floor(bytes))).toString("hex");
}

export function randomJitter(maxExclusive: number): number {
	if (!Number.isFinite(maxExclusive) || maxExclusive <= 0) return 0;
	return randomInt(Math.max(1, Math.floor(maxExclusive)));
}
