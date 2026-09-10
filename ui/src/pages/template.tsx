import { useCallback, useEffect, useState } from "react";
import type { MemberRef, PackageFile, Resolution } from "@/bindings";
import { FileBrowser } from "@/components/files/file-browser";
import { FilePane } from "@/components/files/file-pane";
import { packageFileEntries } from "@/components/files/package-file-rows";
import { PageHeader } from "@/components/page-header";
import { Section } from "@/components/section";
import { DeleteTemplateDialog } from "@/components/templates/delete-template-dialog";
import { RenameTemplateDialog } from "@/components/templates/rename-template-dialog";
import { templateSubject } from "@/components/templates/template-subject";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import { INSTALL_ACTION } from "@/lib/copy-install";
import {
  COPIES_HEADING,
  DELETE_TEMPLATE_LABEL,
  FILES_HEADING,
  lastKnownVersion,
  MISSING_HEADING,
  NO_FILES,
  notSubscribedYet,
  notSubscribedYetAt,
  REMOVE_MEMBER_LABEL,
  RENAME_TEMPLATE_LABEL,
  RESOLVE_READING,
  RESOLVE_UNREADABLE,
  subscribedAs,
} from "@/lib/copy-templates";
import { shortRevision } from "@/lib/labels";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useInstallFlow } from "@/stores/install-flow";
import { useNavStore } from "@/stores/nav";
import {
  resolveTemplate,
  templateFile,
  templateFiles,
  useTemplatesStore,
} from "@/stores/templates";

/** One saved selection: what it installs, what it owns copies of, and the
 *  actions over it. */
export function TemplatePage() {
  const name = useNavStore((s) => s.templateName);
  const templates = useTemplatesStore((s) => s.templates);
  const load = useTemplatesStore((s) => s.load);
  const removeMembers = useTemplatesStore((s) => s.removeMembers);
  const busy = useTemplatesStore((s) => s.busy);
  const refused = useTemplatesStore((s) => s.refused);
  const openInstall = useInstallFlow((s) => s.open);
  const [resolution, setResolution] = useState<Resolution | null>(null);
  const [resolveError, setResolveError] = useState<string | null>(null);
  const [files, setFiles] = useState<PackageFile[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [content, setContent] = useState<string | null>(null);
  const [renaming, setRenaming] = useState(false);
  const [deleting, setDeleting] = useState(false);

  const template = templates.find((one) => one.name === name) ?? null;

  useEffect(() => {
    void load();
  }, [load]);

  const reread = useCallback(async () => {
    if (!name) return;
    setResolveError(null);
    const answer = await resolveTemplate(name);
    if (answer.status === "error") {
      setResolution(null);
      setResolveError(answer.error);
      return;
    }
    setResolution(answer.data);
    const owned = await templateFiles(name);
    setFiles(owned.status === "ok" ? owned.data : []);
  }, [name]);

  useEffect(() => {
    void reread();
  }, [reread]);

  useEffect(() => {
    if (!name || selected === null) {
      setContent(null);
      return;
    }
    let live = true;
    void templateFile(name, selected).then((answer) => {
      if (live) setContent(answer.status === "ok" ? answer.data : answer.error);
    });
    return () => {
      live = false;
    };
  }, [name, selected]);

  if (!name) return null;

  const remove = (member: MemberRef) => {
    void removeMembers(name, [member]).then(() => void reread());
  };

  return (
    <div className="flex h-full flex-col overflow-y-auto">
      <PageHeader
        title={name}
        wide
        action={
          <>
            <Button
              size="sm"
              disabled={template === null}
              onClick={() =>
                template &&
                openInstall({ subjects: [templateSubject(template)] })
              }
            >
              {INSTALL_ACTION}
            </Button>
            <Button
              size="sm"
              variant="outline"
              onClick={() => setRenaming(true)}
            >
              {RENAME_TEMPLATE_LABEL}
            </Button>
            <Button
              size="sm"
              variant="outline"
              className="text-critical"
              onClick={() => setDeleting(true)}
            >
              {DELETE_TEMPLATE_LABEL}
            </Button>
          </>
        }
      />
      <div className={cn("flex flex-col gap-8 pb-10", PAGE_GUTTER)}>
        <div className={cn("flex flex-col gap-8", WIDE_CONTENT_WIDTH)}>
          {refused ? (
            <p className="text-[13px] text-critical">{refused}</p>
          ) : null}
          {resolveError ? (
            <div className="flex items-center gap-3">
              <p className="text-[13px] text-muted-foreground">
                {RESOLVE_UNREADABLE}
              </p>
              <Button size="sm" variant="outline" onClick={() => void reread()}>
                {TRY_AGAIN_LABEL}
              </Button>
            </div>
          ) : null}
          {resolution === null && resolveError === null ? (
            <p className="text-[13px] text-muted-foreground">
              {RESOLVE_READING}
            </p>
          ) : null}

          {resolution?.groups.map((group) => (
            <Section
              key={group.repo}
              title={group.repo}
              description={
                group.source !== null
                  ? subscribedAs(group.source)
                  : group.rev
                    ? notSubscribedYetAt(group.rev)
                    : notSubscribedYet
              }
              action={
                group.version ? (
                  <Badge variant="info">
                    {group.lastKnown
                      ? lastKnownVersion(shortRevision(group.version))
                      : shortRevision(group.version)}
                  </Badge>
                ) : null
              }
            >
              {[
                ...group.items.map((item) => ({
                  kind: item.kind as MemberRef["kind"],
                  name: item.name,
                  off: !item.enabled,
                })),
                ...group.bundles.map((bundle) => ({
                  kind: "bundle" as MemberRef["kind"],
                  name: bundle,
                  off: false,
                })),
              ].map((row) => (
                <MemberRow
                  key={`${row.kind}:${row.name}`}
                  kind={row.kind}
                  name={row.name}
                  detail={row.off ? "switched off" : null}
                  busy={busy}
                  // The repository this section is for, so removing one
                  // of two members sharing a kind and name leaves the
                  // other where it is.
                  onRemove={() =>
                    remove({
                      kind: row.kind,
                      name: row.name,
                      repo: group.repo,
                    })
                  }
                />
              ))}
            </Section>
          ))}

          {resolution && resolution.copies.length > 0 ? (
            <Section title={COPIES_HEADING}>
              {resolution.copies.map((copy) => (
                <MemberRow
                  key={`${copy.kind}:${copy.name}`}
                  kind={copy.kind as MemberRef["kind"]}
                  name={copy.name}
                  detail={copy.from ? `edited copy of ${copy.from}` : null}
                  busy={busy}
                  // A copy the template owns is not a marketplace's, so
                  // there is no repository to tell it apart by: its kind
                  // and name are its identity.
                  onRemove={() =>
                    remove({
                      kind: copy.kind as MemberRef["kind"],
                      name: copy.name,
                      repo: null,
                    })
                  }
                />
              ))}
            </Section>
          ) : null}

          {resolution && resolution.missing.length > 0 ? (
            <Section title={MISSING_HEADING}>
              {resolution.missing.map((member) => (
                <div
                  key={`${member.kind}:${member.name}`}
                  className="flex items-start justify-between gap-4 border-b py-2 last:border-b-0"
                >
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium">
                      {member.kind} {member.name}
                    </p>
                    <p className="text-[13px] text-muted-foreground">
                      {member.repo ? `${member.repo} — ` : ""}
                      {member.why}
                    </p>
                  </div>
                  <div className="flex shrink-0 gap-2">
                    <Button
                      size="sm"
                      variant="outline"
                      onClick={() => void reread()}
                    >
                      {TRY_AGAIN_LABEL}
                    </Button>
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={busy}
                      onClick={() =>
                        remove({
                          kind: member.kind,
                          name: member.name,
                          repo: member.repo,
                        })
                      }
                    >
                      {REMOVE_MEMBER_LABEL}
                    </Button>
                  </div>
                </div>
              ))}
            </Section>
          ) : null}

          <Section title={FILES_HEADING}>
            {files.length === 0 ? (
              <p className="py-2 text-[13px] text-muted-foreground">
                {NO_FILES}
              </p>
            ) : (
              <FileBrowser
                entries={packageFileEntries(files)}
                selected={selected}
                onSelect={setSelected}
                label={FILES_HEADING}
                className="pt-2"
              >
                {selected && content !== null ? (
                  <FilePane
                    path={selected}
                    content={content}
                    truncated={false}
                  />
                ) : null}
              </FileBrowser>
            )}
          </Section>
        </div>
      </div>
      <RenameTemplateDialog
        name={name}
        open={renaming}
        onOpenChange={setRenaming}
      />
      <DeleteTemplateDialog
        name={name}
        open={deleting}
        onOpenChange={setDeleting}
      />
    </div>
  );
}

/** One package a template installs, with the one action a row carries. */
function MemberRow({
  kind,
  name,
  detail,
  busy,
  onRemove,
}: {
  kind: string;
  name: string;
  detail: string | null;
  busy: boolean;
  onRemove: () => void;
}) {
  return (
    <div className="flex items-center justify-between gap-4 border-b py-2 last:border-b-0">
      <div className="min-w-0">
        <p className="truncate text-sm font-medium">{name}</p>
        <p className="text-[13px] text-muted-foreground">
          {kind}
          {detail ? ` — ${detail}` : ""}
        </p>
      </div>
      <Button
        size="sm"
        variant="outline"
        disabled={busy}
        onClick={onRemove}
        className="shrink-0"
      >
        {REMOVE_MEMBER_LABEL}
      </Button>
    </div>
  );
}
