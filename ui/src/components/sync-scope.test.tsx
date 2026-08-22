import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { AuditView, Scope } from "@/bindings";
import { SyncScopeCard } from "./sync-scope";

vi.mock("@/stores/nav", async (importOriginal) => {
  const mod = await importOriginal<typeof import("@/stores/nav")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = { ...mod.useNavStore.getState(), goToPackage: () => {} };
    return selector ? selector(state) : state;
  };
  return { ...mod, useNavStore: Object.assign(hook, mod.useNavStore) };
});

const ONE: Scope = { scope: "project", root: "/work/api" };
const TWO: Scope = { scope: "project", root: "/clients/api" };

const view = (scope: Scope): AuditView => ({
  scope,
  drift: [
    {
      kind: "skill",
      name: "gh",
      harness: "claude",
      scope,
      state: "stale",
      subject: "package",
      detail: "newer content is available",
    },
  ],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  heldBack: [],
  queued: [],
});

const card = (scope: Scope) =>
  renderToStaticMarkup(
    <SyncScopeCard
      view={view(scope)}
      scopes={[ONE, TWO]}
      busy={false}
      onApply={() => {}}
      onDismiss={() => {}}
      onSeeUnmanaged={() => {}}
    />,
  );

// Two projects whose folders share a name are told apart by their parent
// wherever several places are shown. Review is one of those places: its
// rows link per scope, so a heading naming both equally leaves the reader
// unable to tell which card they are acting on — and the full path beside
// the heading is hidden below the wide breakpoint, so the heading itself
// has to carry it.
describe("two projects with the same folder name on Review", () => {
  it("heads each card with a name that is only one of them", () => {
    expect(card(ONE)).toContain(">work/api<");
    expect(card(TWO)).toContain(">clients/api<");
  });
});
