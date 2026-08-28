import type { ReactNode } from "react";
import { STATUS_TONES, type StatusTone } from "@/components/status-note";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { cn } from "@/lib/utils";

/**
 * One place, and what is waiting on the reader there: the headline, the
 * place's own name and path under it, and whatever the caller puts below.
 *
 * Every card on Problems renders through this, so two cards about the same
 * folder cannot say where they are in two different shapes. The tone comes
 * from the one table the app's warnings and errors already share.
 */
export function PlaceCard({
  tone,
  headline,
  name,
  path,
  children,
}: {
  tone: StatusTone;
  headline: string;
  name: string;
  /** The folder, where the place has one. Personal has none. */
  path?: string | null;
  children: ReactNode;
}) {
  const { surface, text } = STATUS_TONES[tone];
  return (
    <Card className={surface}>
      <CardHeader>
        <CardTitle className={cn("text-base", text)}>{headline}</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        <div>
          <p className="break-all text-sm font-medium">{name}</p>
          {path ? (
            <p className="truncate font-mono text-xs text-muted-foreground">
              {path}
            </p>
          ) : null}
        </div>
        {children}
      </CardContent>
    </Card>
  );
}
