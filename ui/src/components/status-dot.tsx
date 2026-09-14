import { cn } from "@/lib/utils";

const TONE_CLASSES = {
  good: "bg-good",
  warning: "bg-warning",
  critical: "bg-critical",
  info: "bg-info",
  notice: "bg-notice",
  customized: "bg-customized",
  muted: "bg-muted-foreground",
} as const;

export function StatusDot({
  tone,
  className,
  title,
}: {
  tone: keyof typeof TONE_CLASSES;
  className?: string;
  /** What the colour means, in words — colour is never the only carrier. */
  title?: string;
}) {
  return (
    <span
      title={title}
      className={cn(
        "size-2 shrink-0 rounded-full",
        TONE_CLASSES[tone],
        className,
      )}
    />
  );
}
