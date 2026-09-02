import type { ReactNode } from "react";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

/** One narrow dropdown in the filter row: "any" leads, the label names it.
 *
 * A presentational control with no knowledge of what it narrows — the tab
 * owns the options and what a chosen value means. Its own file so the tab
 * reads as the list it is. */
export function Filter({
  value,
  onChange,
  label,
  display,
  children,
}: {
  value: string;
  onChange: (value: string) => void;
  label: string;
  /** How a chosen raw value reads to a person. */
  display: (value: string) => string;
  children: ReactNode;
}) {
  return (
    <Select value={value} onValueChange={(next) => onChange(next ?? "any")}>
      <SelectTrigger size="sm" className="w-auto gap-1.5">
        <span className="text-muted-foreground">{label}</span>
        <SelectValue>
          {(current: string) => (current === "any" ? "Any" : display(current))}
        </SelectValue>
      </SelectTrigger>
      <SelectContent>
        <SelectItem value="any">Any</SelectItem>
        {children}
      </SelectContent>
    </Select>
  );
}
