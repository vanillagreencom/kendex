// The package page's version-changing controls: Update, a switch to another
// version, and Follow source. Kept apart from the page's reads because these
// commit — they take the updates store's write hold and read the app's
// derived state back — where everything in `use-package-data.ts` only looks.
import {
  commands,
  type PackageUpdate_Serialize,
  type VersionRow,
} from "@/bindings";
import {
  FOLLOW_SOURCE_TOAST,
  updatedToastLabel,
  VERSION_ERROR_TITLE,
} from "@/lib/copy";
import { UPDATES_ONE_AT_A_TIME_NOTE } from "@/lib/copy-updates";
import { rescanEverything } from "@/lib/rescan";
import { settled } from "@/lib/settled";
import { saying } from "@/lib/undone";
import { workOut } from "@/lib/updates-read-state";
import { versionRowLabel } from "@/lib/versions";
import type { PackageRef } from "@/stores/nav";
import { useProblemsStore } from "@/stores/problems";
import { holdingBusy, useUpdatesStore } from "@/stores/updates";
import { sayApply } from "@/stores/updates-apply";

/** The version-changing actions for one package, each applying the whole
 *  scope and refreshing the app's derived state after. `setBusy` drives
 *  the page's spinner; `reload` refetches the package's own data. */
export function packageVersionActions(
  ref: PackageRef,
  displayName: string,
  held: boolean,
  setBusy: (busy: boolean) => void,
  reload: () => void,
) {
  const showError = (message: string) =>
    useProblemsStore
      .getState()
      .showError({ title: VERSION_ERROR_TITLE, message });
  const afterChange = () => {
    reload();
    // The package's own reads, then the two the whole app derives from —
    // the same call the updates store's own apply makes, on the rule
    // `rescan.ts`'s header states.
    void rescanEverything();
  };
  // Every one of these applies a plan that can refuse a rendering, so
  // none of them toasts off the click: the command's own report says what
  // reached the files, and `done` is only this surface's word for having
  // written the package. This page has no edited-row filter, and a refusal
  // is broader than an edit anyway — files kendex never put there, a
  // provenance clash — so the held answer arrives here whatever the page
  // believes about edits.
  // Under the updates store's `busy` as well as the page's own spinner —
  // these commit like any update does, and one write at a time is what the
  // Updates page's check and its own writes both rest on.
  const run = async (
    call: () => Promise<
      | { status: "ok"; data: PackageUpdate_Serialize }
      | { status: "error"; error: string }
    >,
    done: string,
  ) => {
    // Asked before the command is sent: navigating here mid-write is the
    // overlap that flag rules out.
    if (workOut(useUpdatesStore.getState()))
      return showError(UPDATES_ONE_AT_A_TIME_NOTE);
    setBusy(true);
    return holdingBusy(async () => {
      // A transport failure rejects rather than refusing. Unwrapped it
      // would skip the report, leave `setBusy` up for the life of the view
      // and skip the read-back this promises either way. `saying` because
      // a hold move can take a declaring package away with it.
      const response = saying(await settled(call()));
      setBusy(false);
      if (response.status === "error") {
        showError(response.error);
        // An error is not proof that nothing changed — `lib/rescan.ts`'s
        // header says what does and does not survive a failed apply — so
        // the version this page shows as settled is the engine's answer to
        // give. The page reads back either way.
        afterChange();
        return;
      }
      // One package's apply, so a removal it reports is that package's.
      sayApply(done, response.data, 1);
      afterChange();
    });
  };

  const switchTo = (row: VersionRow) =>
    run(
      () => commands.packageSetRev(ref.scope, ref.kind, ref.name, row.id),
      updatedToastLabel(`${displayName} to ${versionRowLabel(row)}`),
    );

  // A held package moves its hold to the latest; a follower is brought
  // current by the single-package apply — Update never silently pins a
  // follower, and does not move the scope's other followers along. The
  // choice between those two commands is `updates-apply.ts` [`applyRow`]'s
  // to document; this is that rule read off the page's own record instead
  // of off the row, because the page's controls have to work where the
  // update read never spoke for this place and there is no row to ask.
  const updateToLatest = (latest: VersionRow) =>
    held
      ? switchTo(latest)
      : run(
          () => commands.packageUpdate(ref.scope, ref.kind, ref.name),
          updatedToastLabel(displayName),
        );

  const follow = () =>
    run(
      () => commands.packageSetRev(ref.scope, ref.kind, ref.name, null),
      FOLLOW_SOURCE_TOAST,
    );

  return { switchTo, updateToLatest, follow };
}
