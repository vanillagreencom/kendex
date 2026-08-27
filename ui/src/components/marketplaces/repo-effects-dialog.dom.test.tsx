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
  REPO_EFFECTS_NO_REMOVAL,
  REPO_EFFECTS_NOTHING_TO_RUN,
  REPO_EFFECTS_SHARED_NOTE,
  repoEffectsTitle,
} from "@/lib/copy-repo-effects";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { mount, settle } from "@/test/dom";
import { RepoEffectsDialog } from "./repo-effects-dialog";

vi.mock("@/bindings", () => ({
  commands: { repoEffectsApply: vi.fn() },
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
  writes: [{ path: "/home/me/app/.git/hooks/pre-commit", shared: true }],
  companions: [
    { name: "size-ratchet", installed: true },
    { name: "preflight", installed: false },
  ],
};

const show = (queue: Disclosure[]) => {
  useMarketplacesStore.setState({
    pendingEffects: { scope: PROJECT, queue },
    busy: false,
  });
  mount(<RepoEffectsDialog />);
  return document.body;
};

describe("the account a person reads", () => {
  it("carries what changes, where, who takes part, and how to undo it", () => {
    const body = show([guards]);
    const text = body.textContent ?? "";
    expect(text).toContain(repoEffectsTitle("growth-guards"));
    expect(text).toContain(guards.declared.summary);
    expect(text).toContain("~/app/.git/hooks/pre-commit");
    expect(text).toContain(REPO_EFFECTS_SHARED_NOTE);
    expect(text).toContain("size-ratchet");
    expect(text).toContain(COMPANION_INSTALLED);
    expect(text).toContain(COMPANION_NOT_INSTALLED);
    expect(text).toContain("core.hooksPath is never set.");
    expect(text).toContain("run the uninstaller before removing this package");
    expect(text).not.toContain(REPO_EFFECTS_NOTHING_TO_RUN);
  });

  it("never promises a removal the package did not declare", () => {
    const body = show([
      { ...guards, declared: { ...guards.declared, removal: null } },
    ]);
    expect(body.textContent).toContain(REPO_EFFECTS_NO_REMOVAL);
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
      data: null,
    });
    const body = show([guards]);
    const button = Array.from(body.querySelectorAll("button")).find(
      (b) => b.textContent === REPO_EFFECTS_APPLY_LABEL,
    );
    expect(button).toBeDefined();
    await userEvent.click(button as HTMLButtonElement);
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
    const button = Array.from(body.querySelectorAll("button")).find(
      (b) => b.textContent === REPO_EFFECTS_DECLINE_LABEL,
    );
    await userEvent.click(button as HTMLButtonElement);
    await settle();
    expect(commands.repoEffectsApply).not.toHaveBeenCalled();
    expect(useMarketplacesStore.getState().pendingEffects).toBeNull();
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
