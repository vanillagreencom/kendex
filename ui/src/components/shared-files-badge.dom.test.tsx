// @vitest-environment jsdom
import { act } from "react";
import { describe, expect, it } from "vitest";
import type { ObservedItem } from "@/bindings";
import { SharedFilesBadge } from "@/components/shared-files-badge";
import { SHARED_FILES_CONSEQUENCE } from "@/lib/copy";
import { sharedFiles } from "@/lib/derive";
import { mount } from "@/test/dom";

const DEPLOY = "/h/.agents/skills/deploy";
const LINT = "/h/.agents/skills/lint";

const install = (overrides: Partial<ObservedItem>): ObservedItem =>
  ({
    kind: "skill",
    name: "deploy",
    harness: "claude",
    scope: { scope: "global" },
    path: DEPLOY,
    fileState: { state: "dir" },
    enabled: true,
    origin: null,
    summary: null,
    action: null,
    tags: [],
    modifiedAt: null,
    vendor: null,
    ...overrides,
  }) as ObservedItem;

/** One folder both tools read: Codex reaches it through a link of its own,
 *  so the two paths differ and the bytes are one copy. */
const linkedTo = (target: string): ObservedItem[] => [
  install({ path: target }),
  install({
    harness: "codex",
    path: "/h/.codex/skills/deploy",
    fileState: { state: "symlink", target, broken: false },
  }),
];

/** The chip itself. Wrapping it in a tooltip makes the element the
 *  trigger, so that is what the chip is on screen. */
const badge = (host: HTMLElement): HTMLElement => {
  const found = host.querySelector<HTMLElement>(
    '[data-slot="tooltip-trigger"]',
  );
  if (!found) throw new Error("no shared-files badge rendered");
  return found;
};

/** The flyout's own words, opened the way a keyboard opens it. */
const flyout = (host: HTMLElement): string => {
  const trigger = badge(host);
  expect(document.querySelector('[data-slot="tooltip-content"]')).toBeNull();
  act(() => trigger.focus());
  const content = document.querySelector('[data-slot="tooltip-content"]');
  if (!content) throw new Error("focus opened no flyout");
  return content.textContent ?? "";
};

describe("the Shared files badge", () => {
  it("names the shared file, its readers and what sharing costs", () => {
    const host = mount(
      <SharedFilesBadge files={sharedFiles(linkedTo(DEPLOY))} />,
    );
    expect(badge(host).textContent).toContain("Shared files");

    const words = flyout(host);
    // The real path, not the word "shared": a reader who cannot see which
    // file is meant can neither check the claim nor act on it.
    expect(words).toContain(DEPLOY);
    expect(words).toContain("Claude Code and Codex read");
    expect(words).toContain(SHARED_FILES_CONSEQUENCE);
  });

  // The must-fail half: a flyout that printed a fixed sentence would pass
  // the case above while naming a file this package does not share.
  it("names the path these installations actually share", () => {
    const host = mount(
      <SharedFilesBadge files={sharedFiles(linkedTo(LINT))} />,
    );
    const words = flyout(host);
    expect(words).toContain(LINT);
    expect(words).not.toContain(DEPLOY);
  });

  // Nothing shared is no chip at all: a badge explaining itself into saying
  // nothing is worse than the two bare words it replaced.
  it("renders nothing when no two harnesses read one file", () => {
    const apart = [
      install({}),
      install({ harness: "codex", path: "/h/.codex/skills/deploy" }),
    ];
    expect(sharedFiles(apart)).toEqual([]);
    const host = mount(<SharedFilesBadge files={sharedFiles(apart)} />);
    expect(host.querySelector('[data-slot="tooltip-trigger"]')).toBeNull();
    expect(host.textContent).toBe("");
  });
});
