// Per-kind copy for the error modal and the persistent problems list — kept
// out of labels.ts so that file's routine product vocabulary doesn't have to
// carry this denser, failure-specific prose too.
import type { ProblemKind } from "@/stores/problems";

// A v1 lock does not land here — it degrades with a note instead. This kind
// means the lock or manifest is truly unreadable, not merely old.
export const PROBLEM_HEADLINES: Record<ProblemKind, string> = {
  "lock-corrupt": "A kendex file in this project can't be read",
  "schema-too-new": "This project's kendex files come from a newer version",
  "manifest-invalid": "This project's manifest has a problem",
  other: "Something went wrong in this project",
  "scan-failure": "kendex couldn't scan this machine",
};

export const PROBLEM_STEPS: Record<ProblemKind, string[]> = {
  "lock-corrupt": [
    "Rescan to retry",
    "If it keeps failing, the file's contents are damaged — move it aside and apply again to write a fresh one",
  ],
  "schema-too-new": [
    "Update kendex to the latest version",
    "Rescan once you're up to date",
  ],
  "manifest-invalid": [
    "Open the project's kendex.toml and check its syntax",
    "Rescan once it's fixed",
  ],
  other: [
    "Rescan to retry",
    "If it keeps failing, stop tracking this project and re-add it",
  ],
  "scan-failure": [
    "Try scanning again",
    "Check that kendex can still read your harness folders",
  ],
};

export const PROBLEMS_SUBTITLE =
  "Projects kendex couldn't fully check, and what to do about them";
export const PROBLEMS_EMPTY = "No problems right now.";

export const problemsFooterLabel = (count: number): string =>
  count === 1 ? "1 problem" : `${count} problems`;
