import { expect, it } from "vitest";
import type { SubmissionRow } from "@/bindings";
import {
  type Submission,
  submissionFor,
  submissionLine,
  submitLabel,
} from "./mine-submission";

const listed: SubmissionRow = {
  repo: "ada/team-skills",
  status: "pending",
  status_reason: null,
  head_commit: null,
  indexed_at: null,
};

it("keeps submitted, absent and unknown read outcomes distinct", () => {
  const rows: {
    name: string;
    rows: SubmissionRow[] | null;
    error: string | null;
    repo: string | null;
    expected: Submission;
  }[] = [
    {
      name: "no remote after a landed read",
      rows: [listed],
      error: null,
      repo: null,
      expected: { kind: "not-submitted" },
    },
    {
      name: "no remote before a read",
      rows: null,
      error: null,
      repo: null,
      expected: { kind: "not-submitted" },
    },
    {
      name: "no remote after failure",
      rows: [listed],
      error: "offline",
      repo: null,
      expected: { kind: "not-submitted" },
    },
    {
      name: "submitted after a landed read",
      rows: [listed],
      error: null,
      repo: listed.repo,
      expected: { kind: "submitted", row: listed },
    },
    {
      name: "submitted despite a failed read",
      rows: [listed],
      error: "offline",
      repo: listed.repo,
      expected: { kind: "submitted", row: listed },
    },
    {
      name: "absence after a landed read",
      rows: [],
      error: null,
      repo: listed.repo,
      expected: { kind: "not-submitted" },
    },
    {
      name: "absence after failure",
      rows: [],
      error: "offline",
      repo: listed.repo,
      expected: { kind: "unknown" },
    },
    {
      name: "absence before any read",
      rows: null,
      error: null,
      repo: listed.repo,
      expected: { kind: "unknown" },
    },
  ];
  expect(rows).toHaveLength(8);
  for (const row of rows) {
    expect(submissionFor(row.rows, row.error, row.repo), row.name).toEqual(
      row.expected,
    );
  }
});

it("gives unknown a status line without inventing one for an absent submission", () => {
  const rows: {
    name: string;
    state: Submission | null;
    line: string | null;
  }[] = [
    {
      name: "unknown",
      state: { kind: "unknown" },
      line: "Submission status unknown",
    },
    { name: "unanswered", state: null, line: null },
    { name: "not submitted", state: { kind: "not-submitted" }, line: null },
  ];
  expect(rows).toHaveLength(3);
  for (const row of rows)
    expect(submissionLine(row.state), row.name).toBe(row.line);
});

it("offers a first or repeat submit only when that state is known", () => {
  const rows: { name: string; state: Submission | null; label: string }[] = [
    { name: "unknown", state: { kind: "unknown" }, label: "Submit…" },
    { name: "unanswered", state: null, label: "Submit…" },
    {
      name: "not submitted",
      state: { kind: "not-submitted" },
      label: "Submit to community…",
    },
    {
      name: "submitted",
      state: { kind: "submitted", row: listed },
      label: "Re-submit…",
    },
  ];
  expect(rows).toHaveLength(4);
  for (const row of rows)
    expect(submitLabel(row.state), row.name).toBe(row.label);
});
