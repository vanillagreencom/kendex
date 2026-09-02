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

// The reason a row cannot be imported is core's `problem` field, printed
// under the place it belongs to. The label beside the name says only that
// nothing here can be taken, because "not readable" is the wrong cause for
// a Codex agent, which reads fine.
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
});
