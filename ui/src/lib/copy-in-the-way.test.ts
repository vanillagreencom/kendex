import { describe, expect, it } from "vitest";
import { replaceFilesConfirmBody } from "@/lib/copy-in-the-way";

describe("replaceFilesConfirmBody", () => {
  it("names one place and reads as a sentence", () => {
    expect(replaceFilesConfirmBody("~/.claude/skills/deploy", 1, false)).toBe(
      "~/.claude/skills/deploy moves to the trash, and kendex installs what kendex.toml asks for in its place.",
    );
  });

  it("names two places together", () => {
    expect(replaceFilesConfirmBody("~/a · ~/b", 2, false)).toBe(
      "~/a · ~/b move to the trash, and kendex installs what kendex.toml asks for in their place.",
    );
  });

  // Past two the summary is "<first> +2 more", which spliced into a
  // sentence reads as a fragment. The count carries it instead.
  it("counts three or more instead of splicing the summary in", () => {
    const body = replaceFilesConfirmBody("~/a +2 more", 3, false);
    expect(body).toBe(
      "Files at 3 places move to the trash, and kendex installs what kendex.toml asks for instead.",
    );
    expect(body).not.toContain("+2 more");
  });

  it("says the whole project is applied when it is", () => {
    expect(replaceFilesConfirmBody("~/a", 1, true)).toContain(
      "Anything else ready in this project is applied too.",
    );
  });
});
