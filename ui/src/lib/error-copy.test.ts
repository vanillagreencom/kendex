import { describe, expect, it } from "vitest";
import {
  PROBLEM_HEADLINES,
  PROBLEM_LEADS,
  PROBLEM_STEPS,
  problemsFooterLabel,
} from "./error-copy";

describe("problemsFooterLabel", () => {
  it("singularizes exactly one problem", () => {
    expect(problemsFooterLabel(1)).toBe("1 problem");
  });

  it("pluralizes everything else, including zero", () => {
    expect(problemsFooterLabel(0)).toBe("0 problems");
    expect(problemsFooterLabel(3)).toBe("3 problems");
  });
});

// A problem card renders for Personal as readily as for a project, and no
// filename holds across every place a problem arrives from: the two scopes
// keep their locks under different names and their harness files under
// different roots, and a source catalog's install state is
// kendex-local.toml while its kendex.toml is the catalog it publishes
// (`manifest::file::manifest_path`). kendex.toml sat off this list on the
// premise that both scopes call it that, which that routing falsifies — a
// card naming it above an error naming kendex-local.toml points the steps'
// "move the file named above" at the wrong file.
const SCOPE_SPECIFIC = [
  ".kendex-lock.json",
  "lock.json",
  "kendex.toml",
  "kendex-local.toml",
  ".pi",
  ".claude",
  ".codex",
  ".cursor",
];

// A place name the card would pass in, so a lead line is checked as the
// reader sees it rather than as a template.
const PLACE = "acme";

const ALL_LEADS = Object.values(PROBLEM_LEADS)
  .filter((lead) => lead !== null)
  .map((lead) => lead(PLACE));

const ALL_COPY = [
  ...Object.values(PROBLEM_HEADLINES),
  ...Object.values(PROBLEM_STEPS).flat(),
  ...ALL_LEADS,
];

describe("problem copy", () => {
  it("names no path that belongs to one scope", () => {
    for (const line of ALL_COPY) {
      for (const named of SCOPE_SPECIFIC) {
        expect(line, `names ${named}`).not.toContain(named);
      }
    }
  });

  // The card prints the error above these steps and the error carries the
  // path, so the steps point at it rather than spelling one out.
  it("points at the file the error names", () => {
    expect(PROBLEM_STEPS["lock-corrupt"].join(" ")).toContain(
      "the file named above",
    );
    expect(PROBLEM_STEPS["manifest-outdated"].join(" ")).toContain(
      "the file named above",
    );
    expect(PROBLEM_STEPS["manifest-invalid"].join(" ")).toContain(
      "the file named above",
    );
  });

  // The same rule the lock's own refusal holds in crates/core: nothing
  // here can establish whose these files are, so nothing here asks for one
  // to be thrown away.
  it("asks for nothing to be deleted", () => {
    for (const line of ALL_COPY) {
      expect(line.toLowerCase()).not.toContain("delet");
    }
  });
});

// The card's first line, above the verbatim error: it answers "which file,
// where" before a reader meets a sentence the engine wrote for a terminal.
describe("the lead line", () => {
  it("names the place it was given", () => {
    for (const line of ALL_LEADS) expect(line).toContain(PLACE);
  });

  // By role, never by name: the SCOPE_SPECIFIC guard above holds every
  // filename out, so what is left has to say which file it means.
  it("names the file for every kind that has one to name", () => {
    expect(PROBLEM_LEADS["lock-corrupt"]?.(PLACE)).toContain(
      "record of what it installed",
    );
    expect(PROBLEM_LEADS["manifest-outdated"]?.(PLACE)).toContain(
      "declares what it wants installed",
    );
    expect(PROBLEM_LEADS["manifest-invalid"]?.(PLACE)).toContain(
      "declares what it wants installed",
    );
  });

  // A too-new schema can be either file and a scan failure is about no
  // place at all, so a line naming one would be invented.
  it("stays silent where there is no one file to name", () => {
    expect(PROBLEM_LEADS["schema-too-new"]).toBeNull();
    expect(PROBLEM_LEADS.other).toBeNull();
    expect(PROBLEM_LEADS["scan-failure"]).toBeNull();
  });
});
