// The package checks at one project: which state its card names, and the
// action behind the card's one button.
import { toast } from "sonner";
import type {
  AuditView,
  HarnessId,
  ObservedItem,
  Scope,
  SetupHeld,
} from "@/bindings";
import { commands } from "@/bindings";
import { checksHeld, checksOn, ENABLE_FAILED } from "@/lib/copy-package-checks";
import { hookDisplayName } from "@/lib/labels";
import { writingRepo } from "@/lib/rescan";
import { sameScope } from "@/lib/scope";
import { useProblemsStore } from "@/stores/problems";

/** The name core declares the hook under: `drift::hook::HOOK_NAME`. A
 *  rendered registration is scanned as `<event>:<matcher>:<stem>`, whose
 *  stem is this same name. */
export const CHECK_HOOK = "kendex-drift";

/** What a card says the checks are.
 *
 *  `on`: every tool this installation registers the check in runs it here.
 *  `incomplete`: the project declares the check and at least one of those
 *  tools does not run it — the install ran with other changes pending and
 *  only the declaration landed, or something is in the way of the
 *  registration. `off`: neither. `unknown`: no read can say, which is a
 *  state of its own rather than an absence: a card that showed "Off" there
 *  would be offering to install over a project it has not looked at. */
export type ChecksState = "off" | "incomplete" | "on" | "unknown";

/** Where the checks stand, and which of the supported tools each half of
 *  that covers. `targets` is `package_check_targets`' answer: the tools
 *  kendex registers the check in at a project, decided in Rust, because a
 *  discovered hook says a tool is covered and can never say the rest are. */
export interface ChecksStanding {
  state: ChecksState;
  running: HarnessId[];
  waiting: HarnessId[];
}

const NOT_IN_PLACE = ["missing", "stale", "conflict"];

export function checksStanding(
  items: ObservedItem[],
  view: AuditView | undefined,
  failure: string | null,
  root: string,
  targets: readonly HarnessId[] | null,
  folderMissing: boolean,
): ChecksStanding {
  const unknown: ChecksStanding = {
    state: "unknown",
    running: [],
    waiting: [],
  };
  if (folderMissing || targets === null) return unknown;
  const scope: Scope = { scope: "project", root };
  const running = targets.filter((harness) =>
    items.some(
      (item) =>
        item.kind === "hook" &&
        item.harness === harness &&
        sameScope(item.scope, scope) &&
        hookDisplayName(item.name) === CHECK_HOOK,
    ),
  );
  const waiting = targets.filter((harness) => !running.includes(harness));
  if (waiting.length === 0 && targets.length > 0) {
    return { state: "on", running, waiting };
  }
  // Whether the rest are declared-and-waiting or simply not asked for is
  // the audit's to say, and only a landed read of this place says it.
  if (failure !== null || !view || view.error) return unknown;
  const declared = view.drift.some(
    (row) =>
      row.kind === "hook" &&
      row.name === CHECK_HOOK &&
      NOT_IN_PLACE.includes(row.state),
  );
  if (declared || running.length > 0) {
    return { state: "incomplete", running, waiting };
  }
  return { state: "off", running, waiting };
}

/** Switch the checks on at one project, after the person said yes. The
 *  answer is read back from the machine by the command, so a partial setup
 *  says so rather than reporting a success the scope did not reach. The
 *  machine is read again whatever it said, on `lib/rescan.ts`'s rule. */
export async function enableChecks(
  root: string,
  project: string,
): Promise<SetupHeld | null> {
  let held: SetupHeld | null = null;
  await writingRepo(async () => {
    const result = await commands.enablePackageChecks({
      scope: "project",
      root,
    });
    if (result.status === "ok") {
      held = result.data.held;
      toast.success(
        result.data.complete ? checksOn(project) : checksHeld(project),
      );
    } else {
      useProblemsStore.getState().showError({
        title: ENABLE_FAILED,
        message: result.error,
        steps: ["Try again"],
      });
    }
  });
  return held;
}
