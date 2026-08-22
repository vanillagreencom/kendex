import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { ConfirmDialog } from "./confirm-dialog";

// The real dialog portals its content, and static rendering never reaches a
// portal. These stand in for the frame so the footer — the part under test —
// renders where it can be read.
vi.mock("@/components/ui/dialog", () => {
  const plain =
    (tag: string) =>
    ({ children }: { children?: ReactNode }) => (
      <div data-part={tag}>{children}</div>
    );
  return {
    Dialog: plain("dialog"),
    DialogContent: plain("content"),
    DialogDescription: plain("description"),
    DialogFooter: plain("footer"),
    DialogHeader: plain("header"),
    DialogTitle: plain("title"),
  };
});

// Two different reasons a confirmation cannot be given, and they must not
// be told apart by the same flag: one is the action already running, the
// other is a fact the decision rests on still being read. The second leaves
// the way out open.
const render = (extra: { busy?: boolean; holdConfirm?: boolean }) =>
  renderToStaticMarkup(
    <ConfirmDialog
      open
      onOpenChange={() => {}}
      title="Use the new version?"
      confirmLabel="Use new version"
      onConfirm={() => {}}
      {...extra}
    />,
  );

/** Whether the button carrying this label can be pressed. The class
 *  attribute carries the literal `disabled:pointer-events-none`, so only
 *  the rendered attribute answers this. */
const offered = (html: string, label: string) => {
  const at = html.indexOf(`>${label}<`);
  if (at < 0) throw new Error(`no button labelled ${label}`);
  return !html
    .slice(html.lastIndexOf("<button", at), at)
    .includes('disabled=""');
};

describe("a confirmation that cannot be given yet", () => {
  it("offers both while nothing is holding it", () => {
    const html = render({});
    expect(offered(html, "Use new version")).toBe(true);
    expect(offered(html, "Cancel")).toBe(true);
  });

  it("holds everything while the action is running", () => {
    const html = render({ busy: true });
    expect(offered(html, "Use new version")).toBe(false);
    // Leaving mid-flight would not stop it, and the dialog is what says it
    // is still going.
    expect(offered(html, "Cancel")).toBe(false);
  });

  // The gate reached the button that opens the dialog but not the dialog
  // itself, so a read that failed while it stood open still applied what it
  // was about to replace.
  it("holds only the answer while what it rests on is being read", () => {
    const html = render({ holdConfirm: true });
    expect(offered(html, "Use new version")).toBe(false);
    // A dialog with no way out is worse than the answer it is holding back.
    expect(offered(html, "Cancel")).toBe(true);
  });
});
