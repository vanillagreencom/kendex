import type * as React from "react"

import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"

// A value cut short on screen, whole in a tooltip. The trigger is the
// element the text is drawn in, so the hover area is the text a person
// sees. A native `title` is drawn by the webview on its own delay and is
// gone at the first pointer move, before a long path can be read.
function TruncatedText({
  full,
  className,
  children,
}: {
  /** The whole value; nothing is offered on hover without one. */
  full?: string
  className?: string
  children: React.ReactNode
}) {
  return (
    <Tooltip disabled={full === undefined}>
      <TooltipTrigger render={<span className={className} />}>
        {children}
      </TooltipTrigger>
      <TooltipContent>{full}</TooltipContent>
    </Tooltip>
  )
}

export { TruncatedText }
