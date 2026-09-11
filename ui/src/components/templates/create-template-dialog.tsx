import { useEffect, useMemo, useState } from "react";
import type { Chosen, DraftMember, DraftOrigin, Side } from "@/bindings";
import { SectionHeading } from "@/components/section";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  CHOICE_LABEL,
  CHOICE_LOCAL,
  CHOICE_MARKETPLACE,
  COPIES_GO_INTO_THIS_TEMPLATE,
  CREATE_FROM_PROJECT_TITLE,
  choiceHelp,
  DRAFT_READING,
  DRAFT_UNREADABLE,
  EXCLUDED_LABEL,
  INCLUDE_CUSTOMIZATIONS_HELP,
  INCLUDE_CUSTOMIZATIONS_LABEL,
  INCLUDE_LOCAL_HELP,
  INCLUDE_LOCAL_LABEL,
  INCLUDED_PACKAGES_LABEL,
  LICENSE_BASIS_HELP,
  LICENSE_BASIS_LABEL,
  LICENSE_CONFIRM,
  LICENSE_NONE,
  licenseUnder,
  NEW_TEMPLATE_LABEL,
  RESOLVE_OR_EXCLUDE,
  TEMPLATE_NAME_LABEL,
  UNRESOLVED_LABEL,
} from "@/lib/copy-templates";
import { useNavStore } from "@/stores/nav";
import {
  type Draft,
  templateDraft,
  useTemplatesStore,
} from "@/stores/templates";

/** Whether this member's licence question is answered. The rule is
 *  core's — a recognized licence takes a confirmation, anything else a
 *  stated basis — and this is the button's read of it so the save is not
 *  the first place a person hears about it. */
function licenceAnswered(
  origin: Extract<DraftOrigin, { origin: "choice" }>,
  side: Side | undefined,
): boolean {
  // Only the copy side copies a marketplace's bytes, so only it has a
  // licence to answer for.
  if (side?.side !== "copy") return true;
  const answer = side.license;
  // The gate's own rule: a licence kendex recognizes takes the
  // confirmation and nothing else, because a stated basis is what stands
  // in for a licence it cannot judge.
  if (origin.license !== null && origin.licenseRecognized) {
    return answer.confirmed ?? false;
  }
  return (answer.basis ?? "").trim() !== "";
}

/** Where a template would take one member's content from, in one line. */
function originLine(origin: DraftOrigin): string {
  switch (origin.origin) {
    case "marketplace":
      return origin.repo;
    case "copy":
      return origin.at;
    case "choice":
      return origin.repo;
    case "unresolved":
      return origin.why;
  }
}

/** Create a template from everything a project manages.
 *
 *  It opens on the project's own reading: every managed package ticked,
 *  the local packages offered and unticked, and everything a template
 *  cannot carry named with its reason. Nothing in the project changes —
 *  the sentence under the name says so, because that is the one thing a
 *  person needs to be sure of before pressing Create.
 */
export function CreateTemplateDialog({
  project,
  place,
  open,
  onOpenChange,
}: {
  /** The project folder this reads. */
  project: string;
  /** What that project is called among the places beside it. */
  place: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const createFromProject = useTemplatesStore((s) => s.createFromProject);
  const busy = useTemplatesStore((s) => s.busy);
  const refused = useTemplatesStore((s) => s.refused);
  const clearRefusal = useTemplatesStore((s) => s.clearRefusal);
  const goToTemplate = useNavStore((s) => s.goToTemplate);

  const [draft, setDraft] = useState<Draft | null>(null);
  const [readError, setReadError] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [dropped, setDropped] = useState<ReadonlySet<string>>(new Set());
  const [locals, setLocals] = useState<ReadonlySet<string>>(new Set());
  // The side taken per member, and — where that side is the copy — the
  // licence evidence it carries. One piece of state, because the type
  // core takes carries them together: a copy cannot be asked for without
  // its answer.
  const [sides, setSides] = useState<Record<string, Side>>({});
  const [customizations, setCustomizations] = useState(false);

  // Read fresh every time it opens: what it offers is a reading of the
  // project, and a held one would offer packages that have since gone.
  useEffect(() => {
    if (!open) return;
    let live = true;
    setDraft(null);
    setReadError(null);
    setDropped(new Set());
    setLocals(new Set());
    setSides({});
    setCustomizations(false);
    clearRefusal();
    void templateDraft(project).then((answer) => {
      if (!live) return;
      if (answer.status === "error") {
        setReadError(answer.error);
        return;
      }
      setDraft(answer.data);
      setName(answer.data.suggestedName);
    });
    return () => {
      live = false;
    };
  }, [open, project, clearRefusal]);

  const members = draft?.members ?? [];
  const kept = useMemo(
    () => members.filter((member) => !dropped.has(member.key)),
    [members, dropped],
  );
  // A member the template cannot record as it stands blocks the save while
  // it is ticked. Clearing its tick is the other way out, which the line
  // under it says.
  const unresolved = kept.filter(
    (member) =>
      member.origin.origin === "unresolved" ||
      (member.origin.origin === "choice" && sides[member.key] === undefined) ||
      // Taking a marketplace's bytes needs the licence answered. The
      // judgement is core's; this only knows the save will refuse without
      // it, so the button says so before the press rather than after.
      (member.origin.origin === "choice" &&
        !licenceAnswered(member.origin, sides[member.key])),
  );
  const canSave =
    draft !== null &&
    name.trim() !== "" &&
    kept.length + locals.size > 0 &&
    unresolved.length === 0;

  const toggle = (
    held: ReadonlySet<string>,
    key: string,
  ): ReadonlySet<string> => {
    const next = new Set(held);
    if (next.has(key)) next.delete(key);
    else next.add(key);
    return next;
  };

  const submit = () => {
    if (!draft) return;
    const chosen: Chosen = {
      name,
      members: kept.map((member) => member.key),
      locals: [...locals],
      sides,
      customizations,
      // The reading these answers were made against. Core reads the
      // project again and refuses when it no longer offers this, so a
      // package edited while the modal stood is never captured unseen.
      fingerprint: draft.fingerprint,
    };
    void createFromProject(project, chosen).then((ok) => {
      if (!ok) return;
      onOpenChange(false);
      goToTemplate(name.trim());
    });
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{CREATE_FROM_PROJECT_TITLE(place)}</DialogTitle>
          <DialogDescription>{COPIES_GO_INTO_THIS_TEMPLATE}</DialogDescription>
        </DialogHeader>

        {readError ? (
          <div className="flex items-center gap-3">
            <p className="text-[13px] text-muted-foreground">
              {DRAFT_UNREADABLE}
            </p>
            <Button
              size="sm"
              variant="outline"
              onClick={() => {
                setReadError(null);
                void templateDraft(project).then((answer) => {
                  if (answer.status === "ok") {
                    setDraft(answer.data);
                    setName(answer.data.suggestedName);
                  } else setReadError(answer.error);
                });
              }}
            >
              {TRY_AGAIN_LABEL}
            </Button>
          </div>
        ) : null}
        {draft === null && readError === null ? (
          <p className="text-[13px] text-muted-foreground">{DRAFT_READING}</p>
        ) : null}

        {draft ? (
          <div className="flex flex-col gap-6">
            <div className="flex flex-col gap-2">
              <Label htmlFor="template-name">{TEMPLATE_NAME_LABEL}</Label>
              <Input
                id="template-name"
                value={name}
                onChange={(event) => setName(event.target.value)}
              />
            </div>

            {draft.incomplete ? (
              <p className="text-[13px] text-muted-foreground">
                {draft.incomplete.why}
              </p>
            ) : null}

            {members.length > 0 ? (
              <section className="flex flex-col gap-2">
                <SectionHeading>{INCLUDED_PACKAGES_LABEL}</SectionHeading>
                {members.map((member) => (
                  <MemberChoice
                    key={member.key}
                    member={member}
                    checked={!dropped.has(member.key)}
                    onToggle={() => setDropped(toggle(dropped, member.key))}
                    side={sides[member.key]}
                    onSide={(side) =>
                      setSides({ ...sides, [member.key]: side })
                    }
                  />
                ))}
              </section>
            ) : null}

            <section className="flex flex-col gap-2">
              <Label className="flex items-start gap-2 font-normal">
                <Checkbox
                  checked={locals.size > 0}
                  onCheckedChange={() =>
                    setLocals(
                      locals.size > 0
                        ? new Set()
                        : new Set(draft.locals.map((local) => local.key)),
                    )
                  }
                  aria-label={INCLUDE_LOCAL_LABEL}
                />
                <span>
                  <span className="text-sm font-medium">
                    {INCLUDE_LOCAL_LABEL}
                  </span>
                  <span className="block text-[13px] text-muted-foreground">
                    {INCLUDE_LOCAL_HELP}
                  </span>
                </span>
              </Label>
              <div className="flex flex-col gap-1 pl-6">
                {draft.locals.map((local) => (
                  <Label
                    key={local.key}
                    className="flex items-center gap-2 text-[13px] font-normal"
                  >
                    <Checkbox
                      checked={locals.has(local.key)}
                      onCheckedChange={() =>
                        setLocals(toggle(locals, local.key))
                      }
                      aria-label={`${local.kind} ${local.name}`}
                    />
                    <span className="min-w-0 truncate" title={local.at}>
                      {local.name}
                      <span className="text-muted-foreground">
                        {" "}
                        — {local.kind}, {local.at}
                      </span>
                    </span>
                  </Label>
                ))}
              </div>
            </section>

            <Label className="flex items-start gap-2 font-normal">
              <Checkbox
                checked={customizations}
                onCheckedChange={() => setCustomizations(!customizations)}
                aria-label={INCLUDE_CUSTOMIZATIONS_LABEL}
              />
              <span>
                <span className="text-sm font-medium">
                  {INCLUDE_CUSTOMIZATIONS_LABEL}
                </span>
                <span className="block text-[13px] text-muted-foreground">
                  {INCLUDE_CUSTOMIZATIONS_HELP}
                </span>
              </span>
            </Label>

            {draft.excluded.length > 0 ? (
              <section className="flex flex-col gap-1">
                <SectionHeading>{EXCLUDED_LABEL}</SectionHeading>
                {draft.excluded.map((gone) => (
                  <p
                    key={`${gone.kind}:${gone.name}`}
                    className="text-[13px] text-muted-foreground"
                  >
                    {gone.name} — {gone.why}
                  </p>
                ))}
              </section>
            ) : null}
          </div>
        ) : null}

        {refused ? (
          <p className="text-[13px] text-critical">{refused}</p>
        ) : null}
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button disabled={busy || !canSave} onClick={submit}>
            {NEW_TEMPLATE_LABEL}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/** One managed package's row: whether it is in, and — where the project
 *  holds two things under one name — which of them the template saves. */
function MemberChoice({
  member,
  checked,
  onToggle,
  side,
  onSide,
}: {
  member: DraftMember;
  checked: boolean;
  onToggle: () => void;
  side: Side | undefined;
  onSide: (side: Side) => void;
}) {
  const origin = member.origin;
  return (
    <div className="flex flex-col gap-1 border-b py-2 last:border-b-0">
      <Label className="flex items-start gap-2 font-normal">
        <Checkbox
          checked={checked}
          onCheckedChange={onToggle}
          aria-label={`${member.kind} ${member.name}`}
        />
        <span className="min-w-0">
          <span className="text-sm font-medium">{member.name}</span>
          <span className="block text-[13px] text-muted-foreground">
            {member.kind}
            {member.enabled ? "" : " — switched off"}
            {member.requiredBy.length > 0
              ? ` — comes with ${member.requiredBy.join(", ")}`
              : ""}
            {` — ${originLine(origin)}`}
          </span>
        </span>
      </Label>
      {checked && origin.origin === "choice" ? (
        <div className="flex flex-col gap-1 pl-6">
          <p className="text-[13px] text-muted-foreground">
            {CHOICE_LABEL}. {choiceHelp(origin.repo)}
          </p>
          <div className="flex gap-2">
            <Button
              size="sm"
              variant={side?.side === "marketplace" ? "default" : "outline"}
              onClick={() => onSide({ side: "marketplace" })}
            >
              {CHOICE_MARKETPLACE}
            </Button>
            <Button
              size="sm"
              variant={side?.side === "copy" ? "default" : "outline"}
              disabled={origin.hash === null}
              onClick={() =>
                onSide({
                  side: "copy",
                  license: { confirmed: false, basis: null },
                })
              }
            >
              {CHOICE_LOCAL}
            </Button>
          </div>
          {origin.why ? (
            <p className="text-[13px] text-muted-foreground">{origin.why}</p>
          ) : null}
          {/* Taking the project's copy copies the marketplace's bytes, so
              the terms are shown and answered here rather than refused at
              the save. A licence kendex does not recognize cannot be
              confirmed away — it takes a stated reason. */}
          {side?.side === "copy" ? (
            <div className="flex flex-col gap-1">
              <p className="text-[13px] text-muted-foreground">
                {origin.license ? licenseUnder(origin.license) : LICENSE_NONE}
              </p>
              {origin.license && origin.licenseRecognized ? (
                <Label className="flex items-start gap-2 font-normal">
                  <Checkbox
                    checked={side.license.confirmed ?? false}
                    onCheckedChange={() =>
                      onSide({
                        side: "copy",
                        license: {
                          ...side.license,
                          confirmed: !(side.license.confirmed ?? false),
                        },
                      })
                    }
                    aria-label={LICENSE_CONFIRM}
                  />
                  <span className="text-[13px]">{LICENSE_CONFIRM}</span>
                </Label>
              ) : (
                <>
                  <p className="text-[13px] text-muted-foreground">
                    {LICENSE_BASIS_HELP}
                  </p>
                  <Label
                    className="flex flex-col items-start gap-1 font-normal"
                    htmlFor={`license-basis-${member.key}`}
                  >
                    <span className="text-[13px]">{LICENSE_BASIS_LABEL}</span>
                    <Input
                      id={`license-basis-${member.key}`}
                      value={side.license.basis ?? ""}
                      onChange={(event) =>
                        onSide({
                          side: "copy",
                          license: {
                            ...side.license,
                            basis: event.target.value,
                          },
                        })
                      }
                    />
                  </Label>
                </>
              )}
            </div>
          ) : null}
        </div>
      ) : null}
      {checked && origin.origin === "unresolved" ? (
        <p className="pl-6 text-[13px] text-critical">
          {UNRESOLVED_LABEL}. {RESOLVE_OR_EXCLUDE}
        </p>
      ) : null}
    </div>
  );
}
