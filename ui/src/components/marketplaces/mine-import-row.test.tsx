// @vitest-environment jsdom
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { CandidateOrigin, ImportCandidate } from "@/bindings";
import { MineImportRow } from "./mine-import-row";

const candidate = (origins: CandidateOrigin[]): ImportCandidate => ({
  kind: "agent",
  name: "codexer",
  nameProblem: null,
  origins,
});

const row = (origins: CandidateOrigin[]) => (
  <MineImportRow
    candidate={candidate(origins)}
    choice={{
      checked: false,
      hash: "",
      destination: "codexer",
      licenseConfirmed: false,
      licenseBasis: "",
    }}
    onChange={() => {}}
  />
);

// A candidate with nothing selectable says only "not readable now" on its
// own; the reason travels in the location, which core writes there for
// exactly this — an agent in a format a catalog cannot store, a
// marketplace nobody fetched.
describe("a candidate with no selectable bytes", () => {
  it("lists where its bytes were, so the row says why", () => {
    const html = renderToStaticMarkup(
      row([
        {
          group: { group: "unmanaged" },
          locations: ["/home/jane/app/.codex/agents/codexer.toml"],
          hash: "",
          problem:
            "it has no frontmatter, and a catalog stores an agent as markdown",
        },
      ]),
    );
    expect(html).toContain("codexer.toml");
    expect(html).toContain("a catalog stores an agent as markdown");
    expect(html).toContain("nothing kendex can import");
  });

  it("says nothing extra once one origin can be selected", () => {
    const html = renderToStaticMarkup(
      row([
        {
          group: { group: "unmanaged" },
          locations: ["/home/jane/app/.claude/agents/codexer.md"],
          hash: "abc123",
          problem: null,
        },
      ]),
    );
    expect(html).not.toContain("codexer.md");
    expect(html).not.toContain("nothing kendex can import");
  });
});
