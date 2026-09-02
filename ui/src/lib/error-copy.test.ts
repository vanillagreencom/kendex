import { describe, expect, it } from "vitest";
import type { ProblemKind } from "@/stores/problems";
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

// The filenames no problem copy may name, per error-copy.ts's header: a
// place's locks, manifests and harness roots, each of which the engine
// routes by what the place is.
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

// The other half of the same rule: which place this is, is the card's to
// say and not this copy's. `scan-failure` is exempt because its scope is
// known — the machine, no place in it.
const SCOPE_WORDS = ["project", "personal"];

const PLACED_COPY = (Object.keys(PROBLEM_HEADLINES) as ProblemKind[])
  .filter((kind) => kind !== "scan-failure")
  .flatMap((kind) => [
    PROBLEM_HEADLINES[kind],
    ...PROBLEM_STEPS[kind],
    ...(PROBLEM_LEADS[kind] ? [PROBLEM_LEADS[kind](PLACE)] : []),
  ]);

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

  // A kind carrying a scope reaches Personal as readily as a project
  // (`audit_all` seeds `Scope::Global` before any project), so copy naming
  // one renders over a card's name line naming the other.
  it("claims no scope the card's own name line answers", () => {
    for (const line of PLACED_COPY) {
      for (const word of SCOPE_WORDS) {
        expect(line.toLowerCase(), `claims ${word}`).not.toContain(word);
      }
    }
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

  // By role, never by name: SCOPE_SPECIFIC holds out the filenames a lead
  // could reach for, so what is left has to say which file it means.
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
