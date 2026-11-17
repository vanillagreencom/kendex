import { afterEach, expect, spyOn, test } from "bun:test";
import * as tui from "@earendil-works/pi-tui";
import { stableRenderWidth, stripLeadingBackgroundLayer, trimTrailingWhitespaceBeforeAnsi, visibleWidth, wrapTextWithAnsi } from "../tool-renderer/ansi.js";
import { __test } from "../tool-renderer/chrome.js";
import { RESERVED_IMAGE_ROW_MARKER } from "../tool-renderer/overlay.js";
import { useWorld } from "./helpers/world.js";

const world = useWorld();
let wrapSpy: ReturnType<typeof spyOn> | undefined;

afterEach(() => {
	wrapSpy?.mockRestore();
	wrapSpy = undefined;
});

/** The rows renderedToolCore makes of one line, between two sentinel rows so edge trimming leaves it alone. */
function core(line: string, width: number): string[] {
	return __test.renderedToolCore(["●", line, "●"], width, world().cwd)!.slice(1, -1);
}

test("a line that fits comes out unchanged without a wrap call", () => {
	wrapSpy = spyOn(tui, "wrapTextWithAnsi");
	const line = "\x1b[32m● Bash\x1b[39m $ echo hi";
	expect(core(line, 40)).toEqual([line]);
	expect(wrapSpy).not.toHaveBeenCalled();
});

test("a line wider than the guarded width is still wrapped", () => {
	wrapSpy = spyOn(tui, "wrapTextWithAnsi");
	const rows = core(`\x1b[2m${"word ".repeat(20)}\x1b[22m`, 40);
	expect(wrapSpy).toHaveBeenCalled();
	expect(rows.length).toBeGreaterThan(1);
	expect(rows.every((row) => visibleWidth(row) <= 39)).toBe(true);
});

const sgr = (text: string) => `\x1b[38;5;250m${text}\x1b[39m`;
const link = (url: string, text: string, end = "\x07") => `\x1b]8;;${url}${end}${text}\x1b]8;;${end}`;
const corpus = [
	"plain row",
	sgr("● Bash $ npm test"),
	`\x1b[48;5;236m\x1b[38;5;250m  padded box row\x1b[39m${" ".repeat(30)}\x1b[49m`,
	` row padded before a reset${" ".repeat(40)}\x1b[0m`,
	`trailing spaces${" ".repeat(12)}`,
	`\x1b]133;A\x07● Read ${link("file:///repo/src/a.ts", "src/a.ts")}\x1b]133;B\x07`,
	`see ${link("https://example.com/a/very/long/path/that/goes/on", "https://example.com/a/very/long/path/that/goes/on", "\x1b\\")} now`,
	"日本語のテキストを表示する行です",
	"✅ done 🎉 e\u0301 👩‍💻 ok",
	"\tindented\tcolumn\tthree",
	"\x1b_Ga=T,f=100,m=0;AAAA\x1b\\",
	"\x1b]1337;File=inline=1:AAAA\x07",
	`${RESERVED_IMAGE_ROW_MARKER}   `,
	"x".repeat(39),
	"x".repeat(40),
	"averyveryverylongtokenwithoutanyspacesthatmustbebrokenbycharacter",
	`\x1b[4m${"underlined words go on ".repeat(5)}\x1b[24m`,
	sgr(`${"└ output line with words ".repeat(6)}`),
	"全角文字が幅を超えるまで続く長い行の例です全角文字が幅を超えるまで続く",
	"first\nsecond",
	"carriage\rreturn",
	"",
];

test("each corpus line renders as the unconditional wrap rendered it", () => {
	// The old renderedToolCore wrapped every line; the skip must not change one row.
	for (const width of [1, 2, 5, 12, 20, 40, 41, 80, 120]) {
		const renderWidth = stableRenderWidth(width, world().cwd);
		for (const line of corpus) {
			const wrapped = wrapTextWithAnsi(trimTrailingWhitespaceBeforeAnsi(stripLeadingBackgroundLayer(line)), renderWidth);
			expect({ width, line, rows: core(line, width) }).toEqual({ width, line, rows: wrapped.length > 0 ? wrapped : [""] });
		}
	}
});
