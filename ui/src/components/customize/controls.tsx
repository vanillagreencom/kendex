import { type ReactNode, useEffect, useState } from "react";
import { StatusDot } from "@/components/status-dot";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { CUSTOMIZED_MARK } from "@/lib/copy-customize";
import { cn } from "@/lib/utils";

export function Field({
  label,
  set = false,
  children,
}: {
  label: string;
  /** This field holds a value of the reader's. Marked on the label, not
   *  in the box: every box carries a placeholder example, so a place
   *  customized only through Settings otherwise reads as untouched until
   *  someone compares the grid field by field against the examples. */
  set?: boolean;
  children: ReactNode;
}) {
  return (
    <div className="space-y-1">
      <p
        className={cn(
          "flex items-center gap-1.5 text-xs",
          set ? "text-customized" : "text-muted-foreground",
        )}
      >
        {label}
        {set ? (
          <>
            <StatusDot tone="customized" className="size-1.5" />
            {/* Colour is never the only carrier of the fact. */}
            <span className="sr-only">{CUSTOMIZED_MARK}</span>
          </>
        ) : null}
      </p>
      {children}
    </div>
  );
}

/** Picks a name to start customizing; resets to the placeholder after each pick. */
export function AddEntry({
  placeholder,
  options,
  onAdd,
}: {
  placeholder: string;
  options: string[];
  onAdd: (name: string) => void;
}) {
  if (options.length === 0) return null;
  return (
    <Select
      value=""
      onValueChange={(value) => {
        if (value !== null) onAdd(value);
      }}
    >
      <SelectTrigger size="sm" className="w-64">
        <SelectValue placeholder={placeholder} />
      </SelectTrigger>
      <SelectContent>
        {options.map((name) => (
          <SelectItem key={name} value={name}>
            {name}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}

/**
 * Text that is parsed on the way out (comma lists, hook agents) — held raw
 * while typing so a half-written entry is not rewritten under the cursor.
 */
export function CommitInput({
  label,
  value,
  placeholder,
  onCommit,
}: {
  label: string;
  value: string;
  placeholder?: string;
  onCommit: (text: string) => void;
}) {
  const [text, setText] = useState(value);
  useEffect(() => setText(value), [value]);
  return (
    <Input
      aria-label={label}
      value={text}
      placeholder={placeholder}
      onChange={(event) => setText(event.target.value)}
      onBlur={() => onCommit(text)}
    />
  );
}

const TRI_STATE = { true: true, false: false } as const;
const TRI_STATE_LABELS = {
  unset: "Not set",
  true: "True",
  false: "False",
} as const;

export function TriStateSelect({
  label,
  value,
  onChange,
}: {
  label: string;
  value: boolean | null;
  onChange: (value: boolean | null) => void;
}) {
  return (
    <Select
      value={value === null ? "unset" : String(value)}
      onValueChange={(next) => {
        if (next === null || next === "unset") {
          onChange(null);
          return;
        }
        onChange(TRI_STATE[next as "true" | "false"]);
      }}
    >
      <SelectTrigger size="sm" className="w-full" aria-label={label}>
        <SelectValue>
          {(next: "unset" | "true" | "false") => TRI_STATE_LABELS[next]}
        </SelectValue>
      </SelectTrigger>
      <SelectContent>
        <SelectItem value="unset">Not set</SelectItem>
        <SelectItem value="true">True</SelectItem>
        <SelectItem value="false">False</SelectItem>
      </SelectContent>
    </Select>
  );
}
