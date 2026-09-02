import { describe, expect, it } from "vitest";
import type { SubmissionRow } from "@/bindings";
import { submissionFor, submissionLine, submitLabel } from "./mine-submission";

const listed: SubmissionRow = {
  repo: "ada/team-skills",
  status: "pending",
  status_reason: null,
  head_commit: null,
  indexed_at: null,
};

// This ruling used to live in core, where it had unit tests of its own.
// Moving it into the app moved the cases with it: what a marketplace's
// submission reads as turns on how the last read went, and the three
// outcomes have to stay apart.
describe("submissionFor", () => {
  // A submission is keyed by the GitHub repository, so a marketplace with
  // no remote has nothing the server could have listed. No read makes that
  // less certain, so the offer stays a first submit under all three.
  it("is not submitted without a remote, however the read went", () => {
    expect(submissionFor([listed], null, null)).toEqual({
      kind: "not-submitted",
    });
    expect(submissionFor(null, null, null)).toEqual({ kind: "not-submitted" });
    expect(submissionFor([listed], "offline", null)).toEqual({
      kind: "not-submitted",
    });
  });

  // A row already read is what the server last said about that repository,
  // and a later read that failed does not unsay it.
  it("is submitted under the row the server gave, failed read or not", () => {
    expect(submissionFor([listed], null, "ada/team-skills")).toEqual({
      kind: "submitted",
      row: listed,
    });
    expect(submissionFor([listed], "offline", "ada/team-skills")).toEqual({
      kind: "submitted",
      row: listed,
    });
  });

  // Absence means not submitted only where a read landed to say so.
  it("reads absence as not submitted once a read has landed", () => {
    expect(submissionFor([], null, "ada/team-skills")).toEqual({
      kind: "not-submitted",
    });
  });

  it("reads absence as unknown when the last read failed", () => {
    expect(submissionFor([], "offline", "ada/team-skills")).toEqual({
      kind: "unknown",
    });
  });

  // The arm the three above cannot discriminate, and the one the first
  // paint of the tab is in: no read has been made, so there are no rows to
  // be absent from. Answering not-submitted here offers a first submit
  // over work already in review.
  it("reads absence as unknown before any read has been made", () => {
    expect(submissionFor(null, null, "ada/team-skills")).toEqual({
      kind: "unknown",
    });
  });
});

// A read that never landed is not a server that answered with nothing.
// Both surfaces the row draws have to keep them apart: a first submit
// offered over work already in review is the defect, and a blank line
// under it is the same claim made silently.
describe("what an unanswered submission draws", () => {
  it("names the unknown state rather than leaving the row blank", () => {
    expect(submissionLine({ kind: "unknown" })).toBe(
      "Submission status unknown",
    );
    expect(submissionLine(null)).toBeNull();
    expect(submissionLine({ kind: "not-submitted" })).toBeNull();
  });

  it("offers a bare Submit where nothing is known, never a first submit", () => {
    expect(submitLabel({ kind: "unknown" })).toBe("Submit…");
    expect(submitLabel(null)).toBe("Submit…");
  });

  // The control the two above are read against: a landed read saying this
  // marketplace is not listed is what earns the first-submit offer.
  it("offers the first submit only where a read said it is not listed", () => {
    expect(submitLabel({ kind: "not-submitted" })).toBe("Submit to community…");
    expect(submitLabel({ kind: "submitted", row: listed })).toBe("Re-submit…");
  });
});
