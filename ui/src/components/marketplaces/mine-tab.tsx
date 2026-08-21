import { BookOpen, FolderOpen, Hammer, Plus } from "lucide-react";
import { useEffect, useState } from "react";
import { commands } from "@/bindings";
import { EmptyState } from "@/components/empty-state";
import { TextBar } from "@/components/loading";
import { MarkdownView } from "@/components/markdown-view";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { useAccountStore } from "@/stores/account";
import { useMineStore } from "@/stores/mine";
import { MineCreateDialog } from "./mine-create-dialog";
import { MineImportDialog } from "./mine-import-dialog";
import { MineRowCard } from "./mine-row";
import { MineSubmitDialog } from "./mine-submit-dialog";

/** The marketplaces the user authors. Rows are computed fresh from each
 * folder; a folder that stopped reading keeps its place with the reason. */
export function MineTab() {
  const rows = useMineStore((s) => s.rows);
  const load = useMineStore((s) => s.load);
  const registerExisting = useMineStore((s) => s.useExisting);
  const actionError = useMineStore((s) => s.actionError);
  const [creating, setCreating] = useState(false);
  const [importTarget, setImportTarget] = useState<string | null>(null);
  const [doc, setDoc] = useState<string | null>(null);
  const [docOpen, setDocOpen] = useState(false);
  const [submitTarget, setSubmitTarget] = useState<string | null>(null);
  const loadAccount = useAccountStore((s) => s.load);
  const loadSubmissions = useAccountStore((s) => s.loadSubmissions);
  const signedIn = useAccountStore((s) => s.signedIn);
  const submissions = useAccountStore((s) => s.submissions);

  useEffect(() => {
    void load();
    void loadAccount();
  }, [load, loadAccount]);

  useEffect(() => {
    if (!signedIn) return;
    void loadSubmissions();
    // The submissions API names a 60-second poll interval; a row saying
    // "in review" forever after the server listed it would be a lie.
    const timer = setInterval(() => void loadSubmissions(), 60_000);
    return () => clearInterval(timer);
  }, [signedIn, loadSubmissions]);

  const pickExisting = () => {
    void commands.pickFolder().then((picked) => {
      if (picked.status === "ok" && picked.data) {
        void registerExisting(picked.data);
      }
    });
  };

  const openDoc = () => {
    setDocOpen(true);
    if (doc === null) {
      void commands.mineAuthoringDoc().then((text) => setDoc(text));
    }
  };

  const actions = (
    <div className="flex gap-2">
      <Button onClick={() => setCreating(true)}>
        <Plus className="size-4" /> Create a marketplace…
      </Button>
      <Button variant="outline" onClick={pickExisting}>
        <FolderOpen className="size-4" /> Use an existing folder…
      </Button>
      <Button variant="ghost" onClick={openDoc}>
        <BookOpen className="size-4" /> How a marketplace repo works
      </Button>
    </div>
  );

  return (
    <div className="space-y-3">
      {rows === null ? (
        <div className="space-y-3">
          <TextBar width="w-48" title />
          <TextBar width="w-72" />
        </div>
      ) : rows.length === 0 ? (
        <EmptyState
          icon={Hammer}
          title="Nothing you publish yet"
          action={actions}
        >
          Build a marketplace from skills and agents you already have, or start
          an empty one and add to it later.
        </EmptyState>
      ) : (
        <>
          <div className="flex justify-end">{actions}</div>
          {rows.map((entry) =>
            entry.state === "ready" ? (
              <MineRowCard
                key={entry.row.path}
                row={entry.row}
                submission={
                  submissions?.find(
                    (candidate) => candidate.repo === entry.row.git.candidate,
                  ) ?? null
                }
                onImport={(path) => setImportTarget(path)}
                onSubmit={(path) => setSubmitTarget(path)}
              />
            ) : (
              <div
                key={entry.path}
                className="rounded-lg border border-border p-4 text-sm"
              >
                <p className="truncate font-mono text-xs text-muted-foreground">
                  {entry.path}
                </p>
                <p className="text-critical">{entry.why}</p>
              </div>
            ),
          )}
        </>
      )}
      {actionError && !creating && importTarget === null ? (
        <p className="text-sm text-critical" role="alert">
          {actionError}
        </p>
      ) : null}
      <Dialog open={docOpen} onOpenChange={setDocOpen}>
        <DialogContent className="max-w-3xl">
          <DialogHeader>
            <DialogTitle>How a marketplace repo works</DialogTitle>
          </DialogHeader>
          {/* biome-ignore-start lint/a11y/noNoninteractiveTabindex: the
              document is longer than the dialog and carries almost no links,
              so without a tab stop of its own everything past the first
              screen needs a mouse — WKWebView and WebKitGTK, two of the three
              engines the app ships on, do not focus an overflowing container
              by themselves. Reaching a scrollable region by keyboard is what
              the WCAG scrollable-region-focusable rule asks for, and what
              this rule would take away. */}
          <section
            tabIndex={0}
            aria-label="How a marketplace repo works"
            className="max-h-[70vh] overflow-y-auto pr-3 outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50"
          >
            {doc === null ? (
              <TextBar width="w-64" />
            ) : (
              <MarkdownView source={doc} />
            )}
          </section>
          {/* biome-ignore-end lint/a11y/noNoninteractiveTabindex: the rule
              stands for everything else here. */}
        </DialogContent>
      </Dialog>
      <MineSubmitDialog
        path={submitTarget ?? ""}
        open={submitTarget !== null}
        onOpenChange={(open) => {
          if (!open) setSubmitTarget(null);
        }}
        onSubmitted={() => void loadSubmissions()}
      />
      <MineCreateDialog open={creating} onOpenChange={setCreating} />
      <MineImportDialog
        target={importTarget ?? ""}
        open={importTarget !== null}
        onOpenChange={(open) => {
          if (!open) setImportTarget(null);
        }}
      />
    </div>
  );
}
