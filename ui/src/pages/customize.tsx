import { useEffect } from "react";
import { CustomHooks } from "@/components/customize/custom-hooks";
import { CustomizedIndex } from "@/components/customize/customized-index";
import { SaveBar } from "@/components/customize/save-bar";
import { SharedInstructions } from "@/components/customize/shared-instructions";
import { StaleNote } from "@/components/customize/stale-note";
import { DotSpinner } from "@/components/loading";
import { PageHeader } from "@/components/page-header";
import { Section } from "@/components/section";
import { StatusNote } from "@/components/status-note";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  CUSTOMIZE_SUBTITLE,
  CUSTOMIZED_SECTION,
  CUSTOMIZED_SECTION_HELP,
  HOOKS_HELP,
  HOOKS_SECTION,
  SHARED_SECTION,
  SHARED_SECTION_HELP,
} from "@/lib/copy-customize";
import {
  clearItemCustomization,
  sharedCustomization,
} from "@/lib/customization";
import { useCustomizedHere } from "@/lib/customized-here";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { openInventory, useEditorStore } from "@/stores/editor";
import { useSettingsStore } from "@/stores/settings";
import { projectsOf } from "@/stores/settings-projects";
import { useUpdatesStore } from "@/stores/updates";

/** What you have changed that isn't about one package — instructions every
 *  agent and skill gets, hooks of your own, where a project keeps its
 *  skills — and the way in to everything that is. */
export function CustomizePage() {
  const {
    scope,
    draft,
    dirty,
    loading,
    saving,
    error,
    stale,
    setScope,
    load,
    edit,
    save,
  } = useEditorStore();
  const inventory = useEditorStore(openInventory);
  const projects = useSettingsStore(projectsOf);
  const customized = useCustomizedHere(draft, scope);
  const updates = useUpdatesStore((s) => s.read.status);

  // Unsaved edits made on a package's own page live in this same draft;
  // reloading over them here would throw away work with nothing said.
  useEffect(() => {
    if (!useEditorStore.getState().dirty) void load();
  }, [load]);

  return (
    <div className="flex min-h-full flex-col">
      <PageHeader
        title="Customize"
        subtitle={CUSTOMIZE_SUBTITLE}
        action={
          <div className="flex items-center gap-2">
            <span className="text-[13px] text-muted-foreground">Editing</span>
            <Select
              value={scope.scope === "global" ? "global" : scope.root}
              onValueChange={(value) => {
                if (value === null) return;
                void setScope(
                  value === "global"
                    ? { scope: "global" }
                    : { scope: "project", root: value },
                );
              }}
            >
              <SelectTrigger className="w-56" size="sm">
                <SelectValue>
                  {(value: string) =>
                    value === "global" ? "Everything (global)" : value
                  }
                </SelectValue>
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="global">Everything (global)</SelectItem>
                {projects.map((root) => (
                  <SelectItem key={root} value={root}>
                    {root}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        }
      />
      <div className={cn("flex-1", PAGE_BODY)}>
        <div className={cn("flex flex-col gap-10", CONTENT_WIDTH)}>
          {stale ? <StaleNote onReload={() => void load()} /> : null}
          {error ? (
            <StatusNote tone="critical" title="That change couldn't be saved">
              <span className="whitespace-pre-wrap">{error}</span>
            </StatusNote>
          ) : null}
          {loading ? (
            <p className="flex items-center gap-2 text-sm text-muted-foreground">
              <DotSpinner />
              Loading…
            </p>
          ) : null}
          {draft ? (
            <>
              <Section title={SHARED_SECTION} description={SHARED_SECTION_HELP}>
                <SharedInstructions
                  shared={sharedCustomization(draft)}
                  onChange={edit}
                />
              </Section>
              <Section
                title={CUSTOMIZED_SECTION}
                description={CUSTOMIZED_SECTION_HELP}
              >
                <CustomizedIndex
                  items={customized}
                  scope={scope}
                  updates={updates}
                  onRemove={(kind, name) =>
                    edit((current) =>
                      clearItemCustomization(current, kind, name),
                    )
                  }
                />
              </Section>
              <Section title={HOOKS_SECTION} description={HOOKS_HELP}>
                <CustomHooks
                  draft={draft}
                  inventory={inventory}
                  scope={scope}
                  onChange={edit}
                />
              </Section>
            </>
          ) : null}
        </div>
      </div>
      {dirty ? (
        <SaveBar
          saving={saving}
          onSave={() => void save()}
          onDiscard={() => void load()}
        />
      ) : null}
    </div>
  );
}
