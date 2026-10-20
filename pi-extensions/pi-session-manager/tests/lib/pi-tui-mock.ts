import { mock } from "bun:test";

// One mock of @earendil-works/pi-tui for every test file. `bun test ./tests` runs
// the files in one process, and a module Bun has already linked against an earlier
// file's mock keeps that mock's export names, so a later file that adds an export
// fails its import with "Export named ... not found". Every file installs this
// same export set, so the result does not depend on the order the files run in.

export const KEYS: Record<string, string> = {
	"alt+d": "\x1bd",
	"alt+n": "\x1bn",
	"alt+r": "\x1br",
	"alt+s": "\x1bs",
	backspace: "\x7f",
	delete: "\x1b[3~",
	down: "\x1b[B",
	end: "\x1b[F",
	enter: "\r",
	escape: "\x1b",
	home: "\x1b[H",
	return: "\r",
	up: "\x1b[A",
};

class FakeInput {
	focused = false;
	onSubmit: ((value: string) => void) | undefined;
	private value = "";
	getValue(): string {
		return this.value;
	}
	setValue(value: string): void {
		this.value = value;
	}
	handleInput(data: string): void {
		if (!data.startsWith("\x1b")) this.value += data;
	}
	render(): string[] {
		return [this.value];
	}
	invalidate(): void {}
}

export function mockPiTui(): void {
	mock.module("@earendil-works/pi-tui", () => ({
		Input: FakeInput,
		matchesKey: (data: string, key: string) => KEYS[key] === data,
		truncateToWidth: (text: string, width: number) => text.slice(0, width),
		visibleWidth: (text: string) => text.replace(/\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))/g, "").length,
	}));
}
