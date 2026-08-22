import { toast } from "sonner";
import { commands } from "@/bindings";
import { manifestRewritten } from "./manifest-sync";
import { useProblemsStore } from "./problems";
import { useScanStore } from "./scan";
import { refusesForUnsaved } from "./unsaved-first";

// How many of these writes are in flight. The busy flag belongs to all of
// them rather than to whichever finishes first: the offer is made per
// project and two can stand open at once, so the first to land would take
// the Customize Save bar's gate off while the second is still writing.
let writing = 0;

/** Offer to install the session drift report in a project just added.
 *
 *  An offer rather than an auto-install: it declares a hook that injects
 *  into agent context, which is not something to do to someone's project
 *  without asking. Taking it writes that project's kendex.toml, so it owes
 *  what every other writer of that file owes — refusing while unsaved
 *  customization for the place is waiting, and holding the Save bar down
 *  until the editor has been told. */
export function offerDriftHook(
  root: string,
  added: string,
  set: (partial: { busy: boolean }) => void,
): void {
  toast.success(`Added ${added}`, {
    action: {
      label: "Add session drift report",
      onClick: () => {
        if (refusesForUnsaved({ scope: "project", root })) return;
        // Down only once the editor has been told, below: clearing it any
        // earlier leaves a window where a save passes the outdated check
        // and writes the pre-hook file back over the declaration.
        writing += 1;
        set({ busy: true });
        void commands
          .installDriftHook({ scope: "project", root })
          .then(async (result) => {
            if (result.status !== "ok") {
              useProblemsStore.getState().showError({
                title: "Couldn't install the drift report",
                message: result.error,
              });
              return;
            }
            // The declaration lands in that project's kendex.toml, which
            // the Customize tab may be holding a copy of.
            await manifestRewritten({ scope: "project", root });
            // False: the scope had other pending changes, so only the
            // declaration landed — nothing is applied unreviewed.
            toast.success(
              result.data
                ? "Drift report installed"
                : "Drift report added — finish by applying changes in Review",
            );
            void useScanStore.getState().refresh();
          })
          .finally(() => {
            writing -= 1;
            if (writing === 0) set({ busy: false });
          });
      },
    },
  });
}
