import { SaveBar } from "@/components/customize/save-bar";
import { SaveConfirm } from "@/components/customize/save-confirm";
import { saveGroups } from "@/lib/save-summary";
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
    settings,
    confirming,
    requestSave,
    cancelSave,
    load,
    save,
  } = useEditorStore();
  if (!dirty) return null;
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
        hasSecrets={secretEdits.length > 0}
        groups={saveGroups({
          manifestDirty,
          manifestFile,
          settingsEdits,
          secretEdits,
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
