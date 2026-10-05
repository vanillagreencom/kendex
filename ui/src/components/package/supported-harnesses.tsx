import type { ReactNode } from "react";
import type { HarnessId, PackagePreview, RecordSupport } from "@/bindings";
import { HarnessBadge } from "@/components/harness-badge";
import { openLibraryAt } from "@/components/library/use-filter-handoff";
import {
  SUPPORTED_ADVISORY_ON,
  SUPPORTED_ALL,
  SUPPORTED_ALL_EXCEPT,
  SUPPORTED_FALLBACK_ON,
  SUPPORTED_NONE,
  SUPPORTED_UNKNOWN,
} from "@/lib/copy-library";
import { HARNESS_NAMES } from "@/lib/labels";

/** What core answers about the harnesses one package runs on. The available
 *  package's preview carries it, and so does the installed package's record
 *  where core read the package's header ([`RecordHarnesses`]). */
export type HarnessSupport = Pick<
  PackagePreview,
  "unsupported" | "advisory" | "fallback"
>;

const HARNESS_COUNT = Object.keys(HARNESS_NAMES).length;

/** One harness chip, opening that harness, with the package's reason
 *  beside it where it states one. */
function Named({
  harness,
  reason,
}: {
  harness: HarnessId;
  reason: string | null;
}) {
  return (
    <li className="flex min-w-0 items-baseline gap-1.5">
      <HarnessBadge
        harness={harness}
        onOpen={() => openLibraryAt({ harness })}
      />
      {reason ? (
        <span className="min-w-0 text-xs text-muted-foreground">{reason}</span>
      ) : null}
    </li>
  );
}

function Line({ lead, children }: { lead: string; children?: ReactNode }) {
  return (
    <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
      <span>{lead}</span>
      {children ? (
        <ul className="flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-1">
          {children}
        </ul>
      ) : null}
    </div>
  );
}

/** The harnesses a package runs on, said as `kendex show`'s `supported
 *  tools:` line says it: all of them less each unsupported one, then the
 *  ones that take a hook only as advice, then the ones where a fallback
 *  does the hook's job. Core decides every list; this only lays them out. */
export function SupportedHarnesses({ support }: { support: HarnessSupport }) {
  const { unsupported, advisory, fallback } = support;
  const reasons = [
    ...new Set(unsupported.flatMap((gap) => (gap.reason ? [gap.reason] : []))),
  ];
  return (
    <div className="space-y-1">
      {unsupported.length === 0 ? (
        <Line lead={SUPPORTED_ALL} />
      ) : unsupported.length === HARNESS_COUNT ? (
        <Line lead={SUPPORTED_NONE}>
          {reasons.length > 0
            ? reasons.map((reason) => (
                <li key={reason} className="text-xs text-muted-foreground">
                  {reason}
                </li>
              ))
            : null}
        </Line>
      ) : (
        <Line lead={SUPPORTED_ALL_EXCEPT}>
          {unsupported.map((gap) => (
            <Named key={gap.tool} harness={gap.tool} reason={gap.reason} />
          ))}
        </Line>
      )}
      {advisory.length > 0 ? (
        <Line lead={SUPPORTED_ADVISORY_ON}>
          {advisory.map((harness) => (
            <Named key={harness} harness={harness} reason={null} />
          ))}
        </Line>
      ) : null}
      {fallback.length > 0 ? (
        <Line lead={SUPPORTED_FALLBACK_ON}>
          {fallback.map((note) => (
            <Named key={note.tool} harness={note.tool} reason={note.reason} />
          ))}
        </Line>
      ) : null}
    </div>
  );
}

/** The installed package's record: core's lists as [`SupportedHarnesses`]
 *  lays them out, or, where core could not read the hook's header at the
 *  installed revision, why, and no harness at all. */
export function RecordHarnesses({ support }: { support: RecordSupport }) {
  switch (support.state) {
    case "read":
      return <SupportedHarnesses support={support} />;
    case "unread":
      return (
        <Line lead={SUPPORTED_UNKNOWN}>
          <li className="text-xs text-muted-foreground">{support.cause}</li>
        </Line>
      );
    default: {
      const unreachable: never = support;
      return unreachable;
    }
  }
}
