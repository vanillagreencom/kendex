import { type ReactNode, useState } from "react";
import { commands } from "@/bindings";
import { settled } from "@/lib/settled";
import { cn } from "@/lib/utils";

/** A page in the person's browser, opened by the system rather than drawn
 *  in the app's own window.
 *
 *  Which URLs may be opened is the `open_url` command's rule and is not
 *  restated here: a catalog writes its own homepage, and a second copy of
 *  that rule in the UI would drift from the one that actually decides.
 *  What the click gets instead is the refusal, beside the link, so a URL
 *  the app will not follow says so rather than doing nothing. */
export function ExternalLink({
  url,
  children,
  className,
}: {
  url: string;
  children: ReactNode;
  className?: string;
}) {
  const [refused, setRefused] = useState<string | null>(null);
  const open = async () => {
    const answer = await settled(commands.openUrl(url));
    setRefused(answer.status === "error" ? answer.error : null);
  };
  return (
    <>
      <button
        type="button"
        className={cn(
          "text-info underline-offset-2 hover:underline",
          "cursor-pointer",
          className,
        )}
        onClick={() => void open()}
      >
        {children}
      </button>
      {refused ? (
        <span className="text-critical" role="alert">
          {refused}
        </span>
      ) : null}
    </>
  );
}
