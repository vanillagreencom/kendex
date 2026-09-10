import { useState } from "react";
import { InlineMarkdown } from "@/components/inline-markdown";
import { SHOW_LESS_LABEL, SHOW_MORE_LABEL } from "@/lib/copy";
import { previewSummary } from "@/lib/package-summary";

/** What a package's author wrote about it, on the package's own page.
 *
 *  A short summary — which is what the writing guidance asks for — is
 *  simply there. A long one starts bounded and opens in place: this is the
 *  page the previews send a reader to, so the rest of the text has to be
 *  reachable here and nowhere further on. Nothing is dropped. */
export function SummaryText({ summary }: { summary: string }) {
  const [open, setOpen] = useState(false);
  const { shown, truncated } = previewSummary(summary);
  if (!truncated) return <InlineMarkdown source={summary} />;
  return (
    <>
      <InlineMarkdown source={open ? summary : shown} />
      <button
        type="button"
        onClick={() => setOpen(!open)}
        className="mt-1 block text-[13px] font-medium underline underline-offset-2"
      >
        {open ? SHOW_LESS_LABEL : SHOW_MORE_LABEL}
      </button>
    </>
  );
}
