// The app's type hierarchy, in one place.
//
// Four steps, and no page invents a fifth:
//
// | Step | Looks like | Used for |
// |---|---|---|
// | Page title | 24px semibold | one per page, in `PageHeader` |
// | Section title | 15px semibold, full contrast | a group of rows |
// | Row label | 14px medium, full contrast | the thing itself |
// | Description | 13px, muted | the sentence under a label |
//
// A section title used to be an 11px uppercase grey label, which put the
// name of a group below its own contents in the visual order — the eye
// found the rows first and the heading last. Headings now outrank what they
// introduce, which is the whole job of a heading.

import type { ComponentProps, ReactNode } from "react";
import { cn } from "@/lib/utils";

/**
 * A section's name, for layouts that place their own heading rather than
 * using `Section`. Same step in the hierarchy either way.
 */
export function SectionHeading({ className, ...props }: ComponentProps<"h2">) {
  return (
    <h2
      className={cn("text-[15px] font-semibold tracking-tight", className)}
      {...props}
    />
  );
}

export function Section({
  title,
  description,
  action,
  children,
  className,
}: {
  title?: string;
  description?: string;
  /** Sits opposite the title — a link out, a refresh, an add. */
  action?: ReactNode;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section className={cn("flex flex-col gap-1", className)}>
      {title ? (
        <div className="flex min-h-7 items-center justify-between gap-4">
          <SectionHeading>{title}</SectionHeading>
          {action}
        </div>
      ) : null}
      {description ? (
        <p className="max-w-prose text-[13px] text-muted-foreground">
          {description}
        </p>
      ) : null}
      <div className={cn("flex flex-col", title || description ? "mt-2" : "")}>
        {children}
      </div>
    </section>
  );
}

/**
 * One setting: what it is on the left, the control that changes it on the
 * right. No card, no divider — space does the grouping, so a page of these
 * reads as a list of decisions rather than a stack of boxes.
 *
 * The control column is fixed-width so every control on a page lines up in
 * the same lane whatever its label says, and the label column takes the
 * rest. A switch and a dropdown side by side would otherwise sit at two
 * different right edges.
 */
export function SettingRow({
  label,
  description,
  htmlFor,
  role,
  children,
  className,
}: {
  label: ReactNode;
  description?: ReactNode;
  /** Set when the control is a real form field, so the label focuses it. */
  htmlFor?: string;
  /** Set where the row is an announcement rather than a setting — a read
   *  that failed, say — so a screen reader is told when it appears. */
  role?: string;
  children?: ReactNode;
  className?: string;
}) {
  const Label = htmlFor ? "label" : "span";
  return (
    <div
      role={role}
      className={cn(
        "flex items-start justify-between gap-8 py-3.5 first:pt-0",
        className,
      )}
    >
      <div className="flex min-w-0 flex-col gap-1">
        <Label
          htmlFor={htmlFor}
          className={cn(
            "text-sm font-medium",
            htmlFor && "cursor-pointer select-none",
          )}
        >
          {label}
        </Label>
        {description ? (
          <p className="max-w-prose text-[13px] leading-relaxed text-muted-foreground">
            {description}
          </p>
        ) : null}
      </div>
      {children ? (
        <div className="flex shrink-0 items-center justify-end gap-2 pt-0.5">
          {children}
        </div>
      ) : null}
    </div>
  );
}
