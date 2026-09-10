import { useCallback, useEffect, useRef, useState } from "react";
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
  FILES_READING,
  FILES_UNREADABLE,
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
  TEMPLATES_LAST_KNOWN,
  TEMPLATES_UNREADABLE,
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
  useTemplatesAnswer,
  useTemplatesStore,
} from "@/stores/templates";

/** One saved selection: what it installs, what it owns copies of, and the
 *  actions over it. */
export function TemplatePage() {
  const name = useNavStore((s) => s.templateName);
  // Which run of `reread` is the newest. A ref rather than state: it
  // orders the replies and nothing renders from it.
  const issued = useRef(0);
  const answer = useTemplatesAnswer();
  const load = useTemplatesStore((s) => s.load);
  const removeMembers = useTemplatesStore((s) => s.removeMembers);
  const busy = useTemplatesStore((s) => s.busy);
  const refused = useTemplatesStore((s) => s.refused);
  const openInstall = useInstallFlow((s) => s.open);
  const [resolution, setResolution] = useState<Resolution | null>(null);
  const [resolveError, setResolveError] = useState<string | null>(null);
  // Three states, not two: loaded, loaded-and-empty, and a read that
  // failed. Collapsed to two, an unreadable store rendered as the
  // no-copies empty state — a claim over a read that never answered.
  const [files, setFiles] = useState<PackageFile[] | null>(null);
  const [filesError, setFilesError] = useState<string | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [content, setContent] = useState<string | null>(null);
  // The file read's own failure, kept apart from its content so an error
  // is never rendered into the pane as though it were the file.
  const [contentError, setContentError] = useState<string | null>(null);
  const [renaming, setRenaming] = useState(false);
  const [deleting, setDeleting] = useState(false);

  // Which template this page is showing, from an answer that says whether
  // the index was read at all. A read that has not landed or failed with
  // nothing behind it holds no rows, so the page waits or says why rather
  // than presenting a template it cannot find as a template that is gone.
  const template =
    answer.shown === "waiting" || answer.shown === "unreadable"
      ? null
      : (answer.templates.find((one) => one.name === name) ?? null);
  const listFailure =
    answer.shown === "unreadable"
      ? TEMPLATES_UNREADABLE
      : answer.shown === "lastKnown"
        ? TEMPLATES_LAST_KNOWN
        : null;

  useEffect(() => {
    void load();
  }, [load]);

  const reread = useCallback(async () => {
    if (!name) return;
    // Three things start a read of this page — the effect below, Retry,
    // and a member removal — so the replies can arrive in any order. A
    // ticket taken as each run leaves orders them again on arrival: an
    // answer older than the newest run is a view of a template something
    // newer has already replaced, and holding it would put a member the
    // person has just removed back on screen. The same ticket order the
    // templates store keeps, for the same reason.
    const at = ++issued.current;
    const newest = () => at === issued.current;
    if (!newest()) return;
    setResolveError(null);
    const answer = await resolveTemplate(name);
    // The failure branch is ordered too: a late failure over a fresh
    // success would head rows the newer read had just returned.
    if (!newest()) return;
    if (answer.status === "error") {
      setResolution(null);
      setResolveError(answer.error);
      return;
    }
    setResolution(answer.data);
    setFilesError(null);
    const owned = await templateFiles(name);
    if (!newest()) return;
    if (owned.status === "error") {
      setFiles(null);
      setFilesError(owned.error);
      return;
    }
    setFiles(owned.data);
    // The pane cannot outlive its row. A file the refreshed list no longer
    // holds is one this template has just lost, and a selection kept over
    // it would go on drawing the removed member's contents as though the
    // template still owned them. Clearing the selection is what empties
    // the pane: the read below runs off it.
    setSelected((current) =>
      current !== null && !owned.data.some((file) => file.path === current)
        ? null
        : current,
    );
  }, [name]);

  useEffect(() => {
    void reread();
  }, [reread]);

  useEffect(() => {
    if (!name || selected === null) {
      setContent(null);
      setContentError(null);
      return;
    }
    let live = true;
    setContentError(null);
    // The pane is given the new path the moment the selection changes, so
    // bytes held from the file before it would be drawn under a name that
    // is not theirs — and copied under it. Nothing is shown until this
    // read answers.
    setContent(null);
    void templateFile(name, selected).then((answer) => {
      if (!live) return;
      if (answer.status === "error") {
        setContent(null);
        setContentError(answer.error);
        return;
      }
      setContent(answer.data);
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
          {/* The read of the saved templates, where it did not answer.
              Said here because every action in the header is about the
              template this page could not find in it. */}
          {listFailure !== null ? (
            <div className="flex items-center gap-3">
              <p className="text-[13px] text-muted-foreground">{listFailure}</p>
              <Button size="sm" variant="outline" onClick={() => void load()}>
                {TRY_AGAIN_LABEL}
              </Button>
            </div>
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
                // A set's own kind, not "bundle" for both: a plugin
                // installs whole the way a bundle does, and a reference
                // calling it a bundle names no member — the row would
                // remove nothing.
                ...group.bundles.map((set) => ({
                  kind: set.kind as MemberRef["kind"],
                  name: set.name,
                  off: !set.enabled,
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
                  // other where it is — and never reaches the template's
                  // own copy of that name.
                  onRemove={() =>
                    remove({
                      kind: row.kind,
                      name: row.name,
                      which: { of: "marketplace", repo: group.repo },
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
                  // The copy this template owns, named as itself: it
                  // came from no marketplace, and asking by kind and name
                  // alone would take every marketplace member with it.
                  onRemove={() =>
                    remove({
                      kind: copy.kind as MemberRef["kind"],
                      name: copy.name,
                      which: { of: "copy" },
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
                      // Which member this row is about travels with it
                      // from the resolution, so removing an unavailable
                      // one reaches only that one.
                      onClick={() =>
                        remove({
                          kind: member.kind,
                          name: member.name,
                          which: member.which,
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
            {/* The no-copies sentence is a claim, so it is only made over
                a read that answered. A read that failed says so and
                offers itself again. */}
            {filesError !== null ? (
              <div className="flex items-center gap-3 py-2">
                <p className="text-[13px] text-muted-foreground">
                  {FILES_UNREADABLE}
                </p>
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => void reread()}
                >
                  {TRY_AGAIN_LABEL}
                </Button>
              </div>
            ) : files === null ? (
              <p className="py-2 text-[13px] text-muted-foreground">
                {FILES_READING}
              </p>
            ) : files.length === 0 ? (
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
                {/* A read that failed is an error, not the file. Rendered
                    into the pane it read as the file's own contents. */}
                {contentError !== null ? (
                  <p className="text-[13px] text-critical">{contentError}</p>
                ) : selected && content !== null ? (
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
