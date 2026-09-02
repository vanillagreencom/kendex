// @vitest-environment jsdom
// The block a person reads before a package changes how their repository
// works, and the two buttons under it. What is on screen is what the yes
// is for, so every part of the account has to be there — and a package
// with nothing kendex can run gets no button that promises to run it.
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { commands, type Disclosure } from "@/bindings";
import {
  COMPANION_INSTALLED,
  COMPANION_NOT_INSTALLED,
  REPO_EFFECTS_APPLY_LABEL,
  REPO_EFFECTS_DECLINE_LABEL,
  REPO_EFFECTS_DONE_LABEL,
  REPO_EFFECTS_NO_UNDO,
  REPO_EFFECTS_NOTHING_TO_RUN,
  REPO_EFFECTS_SHARED_MARK,
  REPO_EFFECTS_SHARED_NOTE,
  repoEffectsTitle,
} from "@/lib/copy-repo-effects";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { mount, settle } from "@/test/dom";
import { RepoEffectsDialog } from "./repo-effects-dialog";

vi.mock("@/bindings", () => ({
  // The three reads a yes runs behind it: applying an effect runs the
  // package's installer in the repository, so `lib/rescan.ts` reads the
  // machine again whatever it answered. Nothing here is about what they
  // find; unmocked they reject out of a promise nobody awaits.
  commands: {
    repoEffectsApply: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
    libraryProvenance: vi.fn(),
  },
}));
vi.mock("sonner", () => ({
  toast: { success: vi.fn(), info: vi.fn(), error: vi.fn() },
}));

const PROJECT = { scope: "project" as const, root: "/home/me/app" };

const guards: Disclosure = {
  declared: {
    name: "growth-guards",
    root: "/home/me/app/.agents/skills/growth-guards",
    summary: "Arms git hooks, so every commit runs the guard chain.",
    writes: [".git/hooks/pre-commit"],
    installer: "scripts/install-git-hooks",
    uninstaller: "scripts/install-git-hooks --uninstall",
    removal: "run the uninstaller before removing this package",
    notes: ["core.hooksPath is never set."],
    companions: ["size-ratchet", "preflight"],
  },
  name: "growth-guards",
  summary: "Arms git hooks, so every commit runs the guard chain.",
  writes: [{ path: "/home/me/app/.git/hooks/pre-commit", shared: true }],
  companions: [
    { name: "size-ratchet", installed: true },
    { name: "preflight", installed: false },
  ],
  notes: ["core.hooksPath is never set."],
  undo: "run `'.agents/skills/growth-guards/scripts/install-git-hooks' '--uninstall'` from the repository root",
};

const show = (queue: Disclosure[], busy = false) => {
  useMarketplacesStore.setState({
    pendingEffects: { scope: PROJECT, queue },
    busy,
  });
  mount(<RepoEffectsDialog />);
  return document.body;
};

const button = (body: HTMLElement, label: string) =>
  Array.from(body.querySelectorAll("button")).find(
    (b) => b.textContent === label,
  );

describe("the account a person reads", () => {
  it("carries what changes, where, who takes part, and how to undo it", () => {
    const body = show([guards]);
    const text = body.textContent ?? "";
    expect(text).toContain(repoEffectsTitle("growth-guards"));
    expect(text).toContain(guards.summary);
    // The path as core settled it, never an abbreviation: a guess at the
    // home directory names a location other than the one being authorized.
    expect(text).toContain("/home/me/app/.git/hooks/pre-commit");
    expect(text).not.toContain("~/app");
    expect(text).toContain(REPO_EFFECTS_SHARED_NOTE);
    expect(text).toContain("size-ratchet");
    expect(text).toContain(COMPANION_INSTALLED);
    expect(text).toContain(COMPANION_NOT_INSTALLED);
    expect(text).toContain("core.hooksPath is never set.");
    expect(text).toContain(guards.undo ?? "");
    expect(text).not.toContain(REPO_EFFECTS_NOTHING_TO_RUN);
  });

  it("never promises an undo the package did not declare", () => {
    const body = show([{ ...guards, undo: null }]);
    expect(body.textContent).toContain(REPO_EFFECTS_NO_UNDO);
  });

  it("marks the shared paths one by one, never the checkout-local ones", () => {
    // A package writing into `.git/hooks` and into `.github` writes one
    // file every work tree sees and one only this checkout has.
    const body = show([
      {
        ...guards,
        writes: [
          { path: "/home/me/app/.git/hooks/pre-commit", shared: true },
          { path: "/home/me/app/.github/x", shared: false },
        ],
      },
    ]);
    const marked = Array.from(body.querySelectorAll("li")).filter((li) =>
      li.textContent?.includes(REPO_EFFECTS_SHARED_MARK),
    );
    expect(marked).toHaveLength(1);
    expect(marked[0].textContent).toContain(
      "/home/me/app/.git/hooks/pre-commit",
    );
    expect(body.textContent).toContain(REPO_EFFECTS_SHARED_NOTE);
  });

  it("renders the display text as core escaped it, never the raw declaration", () => {
    // Core hands the path through `shown`, so a direction-flipping
    // character arrives as its escape; the raw declaration beside it
    // still carries the character, and must not be what renders.
    const body = show([
      {
        ...guards,
        declared: {
          ...guards.declared,
          writes: [".git/hooks/‮pre-commit"],
        },
        writes: [
          { path: "/home/me/app/.git/hooks/\\u{202e}pre-commit", shared: true },
        ],
      },
    ]);
    const text = body.textContent ?? "";
    expect(text).toContain("\\u{202e}pre-commit");
    expect(text).not.toContain("‮");
  });

  it("renders nothing when nothing is waiting", () => {
    useMarketplacesStore.setState({ pendingEffects: null });
    mount(<RepoEffectsDialog />);
    expect(document.body.textContent).toBe("");
  });
});

describe("the answer", () => {
  it("a yes runs exactly the declaration on screen", async () => {
    vi.mocked(commands.repoEffectsApply).mockResolvedValue({
      status: "ok",
      data: { stdout: [], stderr: [] },
    });
    const body = show([guards]);
    const apply = button(body, REPO_EFFECTS_APPLY_LABEL);
    expect(apply).toBeDefined();
    await userEvent.click(apply as HTMLButtonElement);
    await settle();
    expect(commands.repoEffectsApply).toHaveBeenCalledWith(
      PROJECT,
      guards.declared,
    );
    expect(useMarketplacesStore.getState().pendingEffects).toBeNull();
  });

  it("a no runs nothing and closes", async () => {
    vi.mocked(commands.repoEffectsApply).mockClear();
    const body = show([guards]);
    await userEvent.click(
      button(body, REPO_EFFECTS_DECLINE_LABEL) as HTMLButtonElement,
    );
    await settle();
    expect(commands.repoEffectsApply).not.toHaveBeenCalled();
    expect(useMarketplacesStore.getState().pendingEffects).toBeNull();
  });

  it("closing the dialog is a no", async () => {
    vi.mocked(commands.repoEffectsApply).mockClear();
    show([guards]);
    await userEvent.keyboard("{Escape}");
    await settle();
    expect(commands.repoEffectsApply).not.toHaveBeenCalled();
    expect(useMarketplacesStore.getState().pendingEffects).toBeNull();
  });

  it("while an answer is running, neither button nor Escape answers again", async () => {
    vi.mocked(commands.repoEffectsApply).mockClear();
    const body = show([guards], true);
    expect(
      (button(body, REPO_EFFECTS_APPLY_LABEL) as HTMLButtonElement).disabled,
    ).toBe(true);
    expect(
      (button(body, REPO_EFFECTS_DECLINE_LABEL) as HTMLButtonElement).disabled,
    ).toBe(true);
    await userEvent.keyboard("{Escape}");
    await settle();
    expect(useMarketplacesStore.getState().pendingEffects?.queue).toEqual([
      guards,
    ]);
    expect(commands.repoEffectsApply).not.toHaveBeenCalled();
  });

  it("a package with nothing to run gets no button that would run it", () => {
    const body = show([
      { ...guards, declared: { ...guards.declared, installer: null } },
    ]);
    const labels = Array.from(body.querySelectorAll("button")).map(
      (b) => b.textContent,
    );
    expect(labels).not.toContain(REPO_EFFECTS_APPLY_LABEL);
    expect(labels).toContain(REPO_EFFECTS_DONE_LABEL);
    expect(body.textContent).toContain(REPO_EFFECTS_NOTHING_TO_RUN);
  });
});
