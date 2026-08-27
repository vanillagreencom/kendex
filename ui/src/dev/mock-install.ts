// Installing from a subscription: a bundle or loose items, optionally
// redirected into a project that gains the subscription on the way.
import type {
  Disclosure,
  HarnessId,
  InstallItem,
  ItemKind,
  Scope,
} from "@/bindings";
import { BUNDLE_SPECS } from "./fixture-catalog";
import { packagesKey } from "./fixture-marketplaces";
import { marketplaceRow, offeredHere } from "./mock-catalog";
import { type Handler, same, store } from "./mock-state";

/// Every tool the picker can offer, all of them present on the mock
/// machine — the dev app is a machine with everything installed.
const INSTALL_TARGETS = [
  "claude",
  "codex",
  "opencode",
  "cursor",
  "pi",
  "gemini",
  "copilot",
] as const;

export const installHandlers: Record<string, Handler> = {
  install_targets: ({ kinds }: { kinds: ItemKind[] }) =>
    INSTALL_TARGETS.filter(
      // Cursor takes only skills; the mock machine mirrors that so the
      // picker's own filtering is visible in the dev app.
      (harness) => harness !== "cursor" || kinds.includes("skill"),
    ).map((harness) => ({
      harness,
      detected: true,
      sharesTheUniversalTree: harness !== "claude",
    })),
  marketplace_install: ({
    scope,
    source,
    items,
    bundle,
    destination,
  }: {
    scope: Scope;
    source: string;
    items: InstallItem[];
    bundle: string | null;
    destination: Scope | null;
    hold: boolean;
    harnesses: HarnessId[] | null;
    method: "symlink" | "copy" | null;
  }) => {
    if (items.length === 0 && !bundle) {
      return Promise.reject("nothing selected to install");
    }
    const target = destination ?? scope;
    if (!same(target, scope)) {
      if (target.scope !== "project") {
        return Promise.reject(
          "an install can only be redirected into a project",
        );
      }
      if (scope.scope !== "global") {
        return Promise.reject(
          "only a personal subscription can install into a project",
        );
      }
      // §4.1: the destination project gains the personal subscription it
      // lacks, so the install can resolve there.
      const personal = marketplaceRow(scope, source);
      if (!personal) return Promise.reject(`unknown source '${source}'`);
      if (!marketplaceRow(target, source)) {
        store.state.marketplaces.push({
          ...structuredClone(personal),
          scope: target,
        });
        const offered =
          store.state.marketplacePackages[packagesKey(scope, source)] ?? [];
        store.state.marketplacePackages[packagesKey(target, source)] =
          structuredClone(offered).map((pkg) => ({
            ...pkg,
            state: "available",
          }));
      }
    }
    const offered = offeredHere({ by: "subscription", scope: target, source });
    if (offered instanceof Promise) return offered;
    const wanted: { kind: ItemKind; name: string }[] = [];
    const takeBundle = (name: string) => {
      const spec = BUNDLE_SPECS[source]?.[name];
      if (!spec) return false;
      wanted.push(...spec.members);
      return true;
    };
    if (bundle && !takeBundle(bundle)) {
      return Promise.reject(`no bundle named '${bundle}' in '${source}'`);
    }
    for (const item of items) {
      // A plugin is its registry's curated set, so it installs as one.
      if (item.kind === "plugin") {
        if (!takeBundle(item.name)) {
          return Promise.reject(`'${item.name}' is not offered by '${source}'`);
        }
        continue;
      }
      if (item.kind === "pi-extension") {
        return Promise.reject(
          `'${item.name}' installs with the bundle that carries it, never on its own`,
        );
      }
      wanted.push(item);
    }
    for (const want of wanted) {
      const pkg = offered.find(
        (p) => p.kind === want.kind && p.name === want.name,
      );
      if (!pkg) {
        return Promise.reject(`'${want.name}' is not offered by '${source}'`);
      }
      pkg.state = "installed";
    }
    // The mock catalog's guard package declares what it does to the
    // repository, so the dev app asks the second question for it — and,
    // installed into a project, answers which companion is already here.
    const shown = wanted
      .filter((want) => want.name === "guard")
      .map(() =>
        guardDisclosure(
          target.scope === "project" ? target.root : "/home/me",
          offered.some((p) => p.name === "tests" && p.state === "installed"),
        ),
      );
    return { packages: offered, repoEffects: { shown, withheld: [] } };
  },
  repo_effects_apply: ({ declared }: { declared: Disclosure["declared"] }) => {
    if (declared.installer === null) {
      return Promise.reject(`${declared.name} declares nothing kendex can run`);
    }
    return {
      stdout: [
        "growth-guards git hooks: pre-commit and commit-msg armed in .git/hooks",
      ],
      stderr: [],
    };
  },
};

function guardDisclosure(root: string, testsInstalled: boolean): Disclosure {
  const declared: Disclosure["declared"] = {
    name: "guard",
    root: `${root}/.agents/skills/guard`,
    summary:
      "Arms git pre-commit and commit-msg hooks, so every commit in this repository runs the guard chain — for everyone who commits here, not only for kendex.",
    writes: [
      ".git/hooks/kendex-guards",
      ".git/hooks/pre-commit",
      ".git/hooks/commit-msg",
    ],
    installer: "scripts/install-git-hooks",
    uninstaller: "scripts/install-git-hooks --uninstall",
    removal:
      "run the uninstaller before removing this package: it drops only the helper and one marked line, leaving any hook you wrote.",
    notes: [
      "An existing pre-commit or commit-msg hook keeps its content and its exit status: one marked line goes in after the shebang and falls through to what was already there.",
      "Both hooks block on any nonzero verdict and fail closed on a guard that could not run.",
    ],
    companions: ["tests", "size-ratchet"],
  };
  return {
    declared,
    name: declared.name,
    summary: declared.summary,
    notes: declared.notes,
    undo: "run `'.agents/skills/guard/scripts/install-git-hooks' '--uninstall'` from the repository root",
    writes: [
      { path: `${root}/.git/hooks/kendex-guards`, shared: true },
      { path: `${root}/.git/hooks/pre-commit`, shared: true },
      { path: `${root}/.git/hooks/commit-msg`, shared: true },
    ],
    companions: [
      { name: "tests", installed: testsInstalled },
      { name: "size-ratchet", installed: false },
    ],
  };
}
