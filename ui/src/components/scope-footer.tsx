import type { ItemSafety, ItemWarning } from "@/bindings";
import { RECORDED_DECISIONS_LINK } from "@/lib/copy-decisions";
import { cleanSummaryLead, settledSummaryLead } from "@/lib/copy-safety";
import { groupSkipped, groupWarnings } from "@/lib/group-notes";
import { kindLabel, skipReasonShort } from "@/lib/labels";
import { authorSettledCount, settledCount } from "@/lib/reviewable";
import { useNavStore } from "@/stores/nav";

/**
 * The quiet end of a scope's card: what the check looked at and had nothing
 * to say about, notes about the scope itself, and the items kendex does not
 * manage.
 *
 * These used to be three paragraphs of prose that wrapped for four lines
 * each and read as one grey block. Each is a fact with a name now — a label
 * column and the fact beside it — so the eye can pick out the one it wants
 * instead of reading the lot.
 */
function Fact({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex gap-4 text-[13px]">
      <span className="w-24 shrink-0 text-muted-foreground">{label}</span>
      <div className="flex min-w-0 flex-1 flex-col gap-1">{children}</div>
    </div>
  );
}

const LINK = "underline underline-offset-2 hover:text-muted-foreground";

export function ScopeFooter({
  clean,
  settled,
  notes,
  warnings,
  unmanaged,
  onSeeUnmanaged,
}: {
  /** Rows the check read and had nothing to report on. */
  clean: ItemSafety[];
  /** Rows whose findings someone already ruled on. */
  settled: ItemSafety[];
  notes: string[];
  warnings: ItemWarning[];
  unmanaged: number;
  onSeeUnmanaged: () => void;
}) {
  const goTo = useNavStore((s) => s.goTo);
  const decided = settledCount(settled);
  const byAuthor = authorSettledCount(settled);
  const checked = [
    ...(clean.length > 0 ? [cleanSummaryLead(clean.length)] : []),
    ...(decided > 0 ? [settledSummaryLead(decided, byAuthor)] : []),
  ];
  const skipped = groupSkipped(clean).map((group) => {
    const noun = group.kind
      ? kindLabel(group.kind, group.count).toLowerCase()
      : `item${group.count === 1 ? "" : "s"}`;
    return `${group.count} ${noun} — ${skipReasonShort(group.reason)}`;
  });
  const noted = groupWarnings(warnings);
  if (
    checked.length === 0 &&
    skipped.length === 0 &&
    notes.length === 0 &&
    noted.length === 0 &&
    unmanaged === 0
  )
    return null;

  return (
    <div className="flex flex-col gap-2.5 border-t pt-4">
      {checked.length > 0 || skipped.length > 0 ? (
        <Fact label="Checked">
          <p>
            {checked.join(" · ")}
            {decided > 0 ? (
              <>
                {" "}
                <button
                  type="button"
                  className={LINK}
                  onClick={() => goTo("settings")}
                >
                  {RECORDED_DECISIONS_LINK}
                </button>
              </>
            ) : null}
          </p>
          {skipped.map((line) => (
            <p key={line}>Not checked: {line}</p>
          ))}
        </Fact>
      ) : null}

      {notes.length > 0 || noted.length > 0 ? (
        <Fact label="Notes">
          {notes.map((note) => (
            <p key={note}>{note}</p>
          ))}
          {noted.map((group) => (
            <p key={`${group.message}-${group.remediation ?? ""}`}>
              <span className="break-all font-mono">
                {group.items.map((item) => item.name).join(", ")}
              </span>
              : {group.message}
              {group.remediation ? ` — fix: ${group.remediation}` : ""}
            </p>
          ))}
        </Fact>
      ) : null}
      {unmanaged > 0 ? (
        <Fact label="Not managed">
          <p>
            {unmanaged} item{unmanaged === 1 ? "" : "s"} ·{" "}
            <button type="button" className={LINK} onClick={onSeeUnmanaged}>
              Review them
            </button>
          </p>
        </Fact>
      ) : null}
    </div>
  );
}
