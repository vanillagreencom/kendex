import { ChevronDown, ChevronRight, MoreHorizontal } from "lucide-react";
import { useState } from "react";
import {
  commands,
  type MineRow as MineRowData,
  type StatusFinding,
} from "@/bindings";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { worstSeverityLabel } from "@/lib/copy-safety";
import { SEVERITY_LABELS } from "@/lib/labels";
import { useMineStore } from "@/stores/mine";
import {
  type Submission,
  submissionLine,
  submitLabel,
} from "./mine-submission";

/** A finding's severity in words beside its message, never by
 * implication: the app's own word for a safety severity, the check's own
 * word (error, warning, note) for a structural one. */
function severityWord(finding: StatusFinding): string {
  return finding.pass === "safety" && finding.severity in SEVERITY_LABELS
    ? SEVERITY_LABELS[finding.severity as keyof typeof SEVERITY_LABELS]
    : finding.severity;
}

/** The badge's words for a row with safety findings: the worst one's
 * severity, then the count. */
function findingsBadge(row: MineRowData): string {
  const count = `${row.safetyFindings} finding${row.safetyFindings === 1 ? "" : "s"}`;
  const worst = worstSeverityLabel(
    row.findings.filter((finding) => finding.pass === "safety"),
  );
  return worst ? `${worst} · ${count}` : count;
}

function countsLine(row: MineRowData): string {
  const parts = Object.entries(row.counts).map(
    ([kind, count]) => `${count} ${kind}${count === 1 ? "" : "s"}`,
  );
  if (row.bundles > 0) {
    parts.push(`${row.bundles} bundle${row.bundles === 1 ? "" : "s"}`);
  }
  return parts.length > 0 ? parts.join(" · ") : "nothing found yet";
}

function gitLine(row: MineRowData): string {
  if (!row.git.repository) return "Not a git repository yet";
  const parts: string[] = [];
  parts.push(
    row.git.candidate ? `GitHub: ${row.git.candidate}` : "No GitHub remote yet",
  );
  if (row.git.clean === false) parts.push("uncommitted changes");
  if (row.git.ahead != null && row.git.ahead > 0) {
    parts.push(
      `${row.git.ahead} commit${row.git.ahead === 1 ? "" : "s"} not pushed`,
    );
  }
  return parts.join(" · ");
}

/** One authored marketplace: what kendex found in the folder, what the
 * check says, what git says — and the actions that grow it. */
export function MineRowCard({
  row,
  submission,
  onImport,
  onSubmit,
}: {
  row: MineRowData;
  submission: Submission | null;
  onImport: (path: string) => void;
  onSubmit: (path: string) => void;
}) {
  const forget = useMineStore((s) => s.forget);
  const acceptWorkflow = useMineStore((s) => s.acceptWorkflow);
  const acceptManifest = useMineStore((s) => s.acceptManifest);
  const [showFindings, setShowFindings] = useState(false);
  const problems = row.breakage;
  const status = submissionLine(submission);

  return (
    <div className="rounded-lg border border-border p-4">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <span className="truncate font-medium">{row.name}</span>
            {problems > 0 ? (
              <Badge variant="destructive">
                {problems} problem{problems === 1 ? "" : "s"}
              </Badge>
            ) : row.safetyFindings > 0 ? (
              <Badge variant="secondary">{findingsBadge(row)}</Badge>
            ) : (
              <Badge variant="secondary">check passes</Badge>
            )}
          </div>
          <p className="mt-0.5 truncate text-xs text-muted-foreground">
            {row.path}
          </p>
          <p className="mt-1 text-sm text-muted-foreground">
            {countsLine(row)} · {gitLine(row)}
          </p>
          {status ? (
            <p
              className={
                submission?.kind === "submitted" &&
                submission.row.status === "needs-changes"
                  ? "mt-1 text-sm text-warning"
                  : "mt-1 text-sm text-muted-foreground"
              }
            >
              {status}
            </p>
          ) : null}
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <Button
            variant="outline"
            size="sm"
            onClick={() => onImport(row.path)}
          >
            Import packages…
          </Button>
          <Button size="sm" onClick={() => onSubmit(row.path)}>
            {submitLabel(submission)}
          </Button>
          <DropdownMenu>
            <DropdownMenuTrigger
              render={
                <Button
                  variant="ghost"
                  size="icon"
                  aria-label={`More for ${row.name}`}
                >
                  <MoreHorizontal className="size-4" />
                </Button>
              }
            />
            <DropdownMenuContent align="end">
              {row.declared ? null : (
                <DropdownMenuItem
                  onClick={() =>
                    void acceptManifest(
                      row.path,
                      row.name,
                      row.description ?? "",
                      "",
                    )
                  }
                >
                  Add kendex.toml
                </DropdownMenuItem>
              )}
              <DropdownMenuItem onClick={() => void acceptWorkflow(row.path)}>
                Add the check workflow
              </DropdownMenuItem>
              <DropdownMenuItem
                onClick={() => void commands.revealPath(row.path)}
              >
                Show in file manager
              </DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem onClick={() => void forget(row.path)}>
                Remove from Mine (keeps the folder)
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>
      {row.findings.length > 0 ? (
        <div className="mt-3">
          <button
            type="button"
            className="flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
            onClick={() => setShowFindings((at) => !at)}
          >
            {showFindings ? (
              <ChevronDown className="size-4" />
            ) : (
              <ChevronRight className="size-4" />
            )}
            {row.findings.length} finding{row.findings.length === 1 ? "" : "s"}
          </button>
          {showFindings ? (
            <ul className="mt-2 space-y-2">
              {row.findings.map((finding) => (
                <li
                  key={`${finding.pass}-${finding.file}-${finding.line}-${finding.message}`}
                  className="rounded-md bg-muted/40 p-2 text-sm"
                >
                  <div className="flex items-center justify-between gap-2">
                    <span className="truncate font-mono text-xs">
                      {finding.line === null
                        ? finding.file
                        : `${finding.file}:${finding.line}`}
                    </span>
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() =>
                        void commands.openInEditor(
                          `${row.path}/${finding.file}`,
                        )
                      }
                    >
                      Open
                    </Button>
                  </div>
                  <p>
                    <span className="font-medium">
                      {severityWord(finding)}:{" "}
                    </span>
                    {finding.message}
                  </p>
                  <p className="text-xs text-muted-foreground">
                    Fix: {finding.fix}
                  </p>
                </li>
              ))}
            </ul>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
