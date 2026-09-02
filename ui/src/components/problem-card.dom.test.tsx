// @vitest-environment jsdom
// The card a person reaches when kendex could not read one of its own
// files. What it says first, and how the two blocks under that read: the
// engine's message is the longest thing on the card and the only line
// carrying the path, and the steps are prose a reader works through.
import { describe, expect, it, vi } from "vitest";
import type { Scope } from "@/bindings";
import { ProblemCard } from "@/components/problem-card";
import { PROBLEM_LEADS } from "@/lib/error-copy";
import type { Problem } from "@/stores/problems";
import { mount } from "@/test/dom";

vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: { revealPath: vi.fn(), scanMachine: vi.fn(), auditAll: vi.fn() },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const ACME: Scope = { scope: "project", root: "/work/acme" };
const MESSAGE =
  "/work/acme/.kendex-lock.json: this lock file could not be read";

const unreadableLock: Problem = {
  key: "/work/acme",
  scope: ACME,
  kind: "lock-corrupt",
  message: MESSAGE,
};

/** The paragraph holding the engine's verbatim message. */
const errorBlock = (host: HTMLElement) =>
  [...host.querySelectorAll("p")].find((p) => p.textContent === MESSAGE);

describe("a file kendex could not read", () => {
  it("says which project and which file before the verbatim error", () => {
    const host = mount(<ProblemCard problem={unreadableLock} />);

    const lead = PROBLEM_LEADS["lock-corrupt"]?.("acme");
    expect(lead).toBeDefined();
    const said = host.textContent ?? "";
    expect(said).toContain(lead);
    // Before, not merely present: the plain words are what a reader meets
    // first, and the terminal sentence explains them.
    expect(said.indexOf(lead as string)).toBeLessThan(said.indexOf(MESSAGE));
  });

  // The tint the card's trim wears is not one to set its longest line in.
  it("sets the error in the card's own text colour", () => {
    const host = mount(<ProblemCard problem={unreadableLock} />);

    expect(errorBlock(host)?.className).not.toContain("text-muted-foreground");
  });

  // The steps are prose, so they read at the size the rest of the page
  // does rather than a notch under it.
  it("sets the steps at body size", () => {
    const host = mount(<ProblemCard problem={unreadableLock} />);

    const steps = host.querySelector("ul");
    expect(steps?.className).toContain("text-sm");
    expect(steps?.className).not.toContain("text-xs");
  });
});

// The one problem about no project at all: nothing to name, so nothing is
// invented above the message.
describe("a scan that could not finish", () => {
  it("leads with the engine's message itself", () => {
    const host = mount(
      <ProblemCard
        problem={{
          key: "scan",
          scope: null,
          kind: "scan-failure",
          message: "the machine could not be read",
        }}
      />,
    );

    expect(host.textContent).toContain("the machine could not be read");
    expect(host.textContent).not.toContain("The file is");
  });
});
