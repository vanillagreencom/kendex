import { Info } from "lucide-react";
import { useState } from "react";
import type { SecretEdit, SecretRow } from "@/bindings";
import { StatusLine } from "@/components/status-note";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import {
  SECRET_CANCEL_ACTION,
  SECRET_CLEAR_ACTION,
  SECRET_CLEARING,
  SECRET_HELP_LABEL,
  SECRET_INPUT_PLACEHOLDER,
  SECRET_NOT_SET,
  SECRET_REPLACE_ACTION,
  SECRET_REQUIRED,
  SECRET_SET,
  SECRET_SET_ACTION,
  SECRET_SET_NOTE,
  SECRET_UNKNOWN,
  secretFieldHelp,
} from "@/lib/copy-customize";

/**
 * One credential a package declares: whether this project has one stored,
 * what it lets the package do, and the three things a person can do about
 * it.
 *
 * The field is masked and starts empty whatever is stored, because nothing
 * on this page ever holds the value. The read says a key is set and not
 * what it is set to, so there is nothing to prefill — and a box that
 * looked prefilled would invite a save that rewrote a key the person only
 * meant to look at. Leaving the field alone is therefore the same as
 * leaving the stored value alone, which is why Set and Replace open the
 * box rather than the box always being there.
 *
 * "Set" is a fact about the file and never about the provider: kendex
 * stores what it is given and asks nobody whether it works.
 */
export function SecretFieldRow({
  skill,
  row,
  file,
  writable,
  edit,
  onEdit,
  onCancel,
}: {
  skill: string;
  row: SecretRow;
  /** Where a value typed here would go, as the read resolved it. */
  file: string;
  /** Whether anything may be written there at all. */
  writable: boolean;
  /** This field's unsaved answer, where one has been given. */
  edit?: SecretEdit;
  onEdit: (edit: SecretEdit) => void;
  /** Take this field's answer back: leave whatever is stored alone. */
  onCancel: () => void;
}) {
  const typing = edit?.value.kind === "set";
  const [open, setOpen] = useState(false);
  const editing = typing || open;
  const stored = row.current.state === "set";
  const clearing = edit?.value.kind === "clear";
  // Two things stop a write, and a control that offered one anyway would
  // only fail on Save. The destination may refuse every key, and this key
  // may be one core will not write over — assigned more than once, or in a
  // shape kendex does not write — which is what leaves it unknown.
  const settable = writable && row.current.state !== "unknown";

  const close = () => {
    setOpen(false);
    onCancel();
  };

  return (
    <div className="flex items-start gap-8 py-3.5 first:pt-0">
      <div className="flex min-w-0 flex-1 flex-col gap-1">
        <span className="flex items-center gap-1.5 text-sm font-medium">
          <code className="font-mono text-[13px]">{row.key}</code>
          <Tooltip>
            <TooltipTrigger
              // Hover, focus and touch all reach the same words, and the
              // words are in the trigger too so a screen reader never
              // depends on the popup opening at all.
              className="inline-flex shrink-0 items-center rounded-full text-muted-foreground outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50"
              aria-label={`${SECRET_HELP_LABEL}: ${row.key}`}
            >
              <Info className="size-3.5" />
              <span className="sr-only">{secretFieldHelp(file)}</span>
            </TooltipTrigger>
            <TooltipContent className="max-w-72">
              {secretFieldHelp(file)}
            </TooltipContent>
          </Tooltip>
          <State row={row} />
          {row.required ? (
            <Badge variant="outline">{SECRET_REQUIRED}</Badge>
          ) : null}
        </span>
        <p className="max-w-prose text-[13px] leading-relaxed text-muted-foreground">
          {row.explainer.join(" ").trim()}
          {stored && !clearing ? (
            <span className="mt-1 block">{SECRET_SET_NOTE}</span>
          ) : null}
        </p>
        {row.current.state === "unknown" ? (
          <StatusLine tone="warning">{row.current.reason}</StatusLine>
        ) : null}
        {clearing ? (
          <StatusLine tone="info">{SECRET_CLEARING}</StatusLine>
        ) : null}
      </div>
      <div className="flex w-1/2 shrink-0 flex-col items-end gap-2 pt-0.5">
        {editing ? (
          <>
            <Input
              type="password"
              autoComplete="off"
              spellCheck={false}
              aria-label={row.key}
              className="w-full"
              placeholder={SECRET_INPUT_PLACEHOLDER}
              value={edit?.value.kind === "set" ? edit.value.value : ""}
              onChange={(event) =>
                onEdit({
                  skill,
                  key: row.key,
                  value: { kind: "set", value: event.target.value },
                })
              }
            />
            <Button variant="ghost" size="sm" onClick={close}>
              {SECRET_CANCEL_ACTION}
            </Button>
          </>
        ) : (
          <div className="flex gap-2">
            <Button
              variant="outline"
              size="sm"
              disabled={!settable}
              onClick={() => setOpen(true)}
            >
              {stored ? SECRET_REPLACE_ACTION : SECRET_SET_ACTION}
            </Button>
            {stored && !clearing ? (
              <Button
                variant="ghost"
                size="sm"
                disabled={!settable}
                onClick={() =>
                  onEdit({ skill, key: row.key, value: { kind: "clear" } })
                }
              >
                {SECRET_CLEAR_ACTION}
              </Button>
            ) : null}
            {clearing ? (
              <Button variant="ghost" size="sm" onClick={onCancel}>
                {SECRET_CANCEL_ACTION}
              </Button>
            ) : null}
          </div>
        )}
      </div>
    </div>
  );
}

/** The three answers, each said in words. Not set and can't check are
 *  different facts: a person told a key is missing sets it again, over
 *  whatever is there. */
function State({ row }: { row: SecretRow }) {
  if (row.current.state === "set")
    return <Badge variant="good">{SECRET_SET}</Badge>;
  if (row.current.state === "not-set")
    return <Badge variant="outline">{SECRET_NOT_SET}</Badge>;
  return <Badge variant="warning">{SECRET_UNKNOWN}</Badge>;
}
