import { useId } from "react";
import { cn } from "@/lib/utils";

/**
 * One control holding a small closed set of choices, exactly one of them
 * chosen. Distinct from [Pill], which narrows what a section shows and can
 * be off: a segment is never off, so the group is drawn as one control with
 * a moving selection rather than as loose words a person has to read as a
 * set.
 *
 * Real radio inputs under the labels, not buttons wearing a radio role: the
 * browser then gives arrow-key movement, the one-tab-stop-per-group
 * behaviour and the "N of M" announcement for free, and they are the same
 * semantics a screen reader would get from any other radio group in the
 * app.
 */
export function Segmented<Value extends string>({
  value,
  onChange,
  options,
  label,
  className,
}: {
  value: Value;
  onChange: (value: Value) => void;
  options: { value: Value; label: string }[];
  /** What the group as a whole chooses, for anyone who cannot see it. */
  label: string;
  className?: string;
}) {
  // One name per mounted group, so two segmented controls on a page do not
  // become one radio group between them.
  const name = useId();
  return (
    <fieldset
      className={cn(
        "inline-flex items-center gap-0.5 rounded-lg border bg-muted/50 p-0.5",
        className,
      )}
    >
      <legend className="sr-only">{label}</legend>
      {options.map((option) => {
        const selected = option.value === value;
        return (
          <label
            key={option.value}
            className={cn(
              "inline-flex h-7 cursor-pointer items-center rounded-md px-3 text-xs font-medium transition-colors",
              "has-focus-visible:ring-[3px] has-focus-visible:ring-ring/50",
              selected
                ? "bg-background text-foreground shadow-sm"
                : "text-muted-foreground hover:text-foreground",
            )}
          >
            <input
              type="radio"
              name={name}
              className="sr-only"
              value={option.value}
              checked={selected}
              onChange={() => onChange(option.value)}
            />
            {option.label}
          </label>
        );
      })}
    </fieldset>
  );
}
