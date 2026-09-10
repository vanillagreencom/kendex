import { SaveBar } from "@/components/customize/save-bar";
import { SaveConfirm } from "@/components/customize/save-confirm";
import { saveGroups } from "@/lib/save-summary";
import { answeredEdits } from "@/lib/secret-rows";
import { useEditorStore } from "@/stores/editor";

/**
 * The Save bar and the summary it opens, as one thing.
 *
 * Pressing Save writes nothing. It re-reads the place and shows every file
 * the save is about to write, because a save can now reach three of them —
 * the manifest, the tracked settings file, and the project's private file
 * — and a person typing a credential has to see which one it lands in
 * before it lands there. Confirming runs the same save that used to run
 * straight from the bar; cancelling keeps the draft.
 */
export function CustomizeSaveBar({ busy = false }: { busy?: boolean }) {
  const {
    dirty,
    saving,
    manifestDirty,
    manifestFile,
    settingsEdits,
    secretEdits,
    secretFile,
    settings,
    confirming,
    requestSave,
    cancelSave,
    load,
    save,
  } = useEditorStore();
  if (!dirty) return null;
  const answered = answeredEdits(secretEdits);

  return (
    <>
      <SaveBar
        saving={saving}
        busy={busy}
        onSave={() => void requestSave()}
        onDiscard={() => void load()}
      />
      <SaveConfirm
        open={confirming}
        saving={saving}
        // The same edits the save will carry, not every edit in hand: a
        // field typed into and erased is no longer an answer, and a
        // dialog counting one would name the private file and its key
        // over a save that writes neither.
        hasSecrets={answered.length > 0}
        groups={saveGroups({
          manifestDirty,
          manifestFile,
          settingsEdits,
          secretEdits: answered,
          pickedFile: secretFile,
          settings,
        })}
        onOpenChange={(open) => {
          if (!open) cancelSave();
        }}
        onConfirm={() => void save()}
      />
    </>
  );
}
