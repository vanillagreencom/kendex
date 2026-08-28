import { CheckCircle2, Info, OctagonAlert, TriangleAlert } from "lucide-react";
import type { ReactNode } from "react";
import { cn } from "@/lib/utils";

/** The four things the app ever has to say about state, and the one look
 *  each of them wears. Sharing the table is the point: a warning that
 *  borrows the error colour teaches people to distrust the colour. */
export const STATUS_TONES = {
  critical: {
    icon: OctagonAlert,
    text: "text-critical",
    surface: "border-critical/30 bg-critical/5",
  },
  warning: {
    icon: TriangleAlert,
    text: "text-warning",
    surface: "border-warning/30 bg-warning/5",
  },
  info: {
    icon: Info,
    text: "text-info",
    surface: "border-info/30 bg-info/5",
  },
  good: {
    icon: CheckCircle2,
    text: "text-good",
    surface: "border-good/30 bg-good/5",
  },
} as const;

export type StatusTone = keyof typeof STATUS_TONES;

/** Holds the tone icon in a box as tall as one line of the text beside it,
 *  so the icon reads as centred on that line however the words wrap. */
function IconSlot({ line, children }: { line: string; children: ReactNode }) {
  return (
    <span className={cn("flex shrink-0 items-center", line)}>{children}</span>
  );
}

/** A boxed remark about state — the shape errors, warnings and notices all
 *  take. `title` carries the headline; children carry any detail. */
export function StatusNote({
  tone,
  title,
  children,
  action,
  className,
}: {
  tone: StatusTone;
  title: ReactNode;
  children?: ReactNode;
  action?: ReactNode;
  className?: string;
}) {
  const { icon: Icon, text, surface } = STATUS_TONES[tone];
  return (
    <div
      className={cn("flex gap-3 rounded-lg border p-3", surface, className)}
      role={tone === "critical" ? "alert" : undefined}
    >
      <IconSlot line="h-5">
        <Icon className={cn("size-4", text)} />
      </IconSlot>
      <div className="min-w-0 flex-1 text-sm">
        <p className={cn("font-medium", text)}>{title}</p>
        {children ? (
          <div className="mt-1 text-muted-foreground">{children}</div>
        ) : null}
      </div>
      {action ? <div className="shrink-0">{action}</div> : null}
    </div>
  );
}

/** The same vocabulary at caption scale, for a remark that belongs under
 *  the control it is about rather than in a box of its own. */
export function StatusLine({
  tone,
  children,
  className,
}: {
  tone: StatusTone;
  children: ReactNode;
  className?: string;
}) {
  const { icon: Icon, text } = STATUS_TONES[tone];
  return (
    <p
      className={cn("flex items-start gap-1.5 text-xs", text, className)}
      role={tone === "critical" ? "alert" : undefined}
    >
      <IconSlot line="h-4">
        <Icon className="size-3.5" />
      </IconSlot>
      <span className="min-w-0">{children}</span>
    </p>
  );
}
