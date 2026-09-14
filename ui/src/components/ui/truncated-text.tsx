import type * as React from "react"

import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip"

// A value cut short on screen, whole in a tooltip. The trigger is the
// element the text is drawn in, so the hover area is the text a person
// sees, and the popup follows the pointer along a wide value. A native
// `title` is drawn by the webview on its own delay and is gone at the
// first pointer move, before a long path can be read.
function TruncatedText({
  full,
  className,
  render,
  disabled = false,
  children,
}: {
  /** The whole value; nothing is offered on hover without one. */
  full?: string
  className?: string
  /** The element the text is drawn in, where it is not a plain span: a
   *  button another trigger also owns. `className` is then unused. */
  render?: React.ReactElement
  /** Hold the tooltip shut, as while a menu this trigger opens is open. */
  disabled?: boolean
  children: React.ReactNode
}) {
  return (
    <Tooltip disabled={disabled || full === undefined} trackCursorAxis="x">
      <TooltipTrigger render={render ?? <span className={className} />}>
        {children}
        {/* The popup exists only while open and the trigger names no
            description, so the whole value reaches a screen reader here. */}
        {full === undefined ? null : <span className="sr-only">{full}</span>}
      </TooltipTrigger>
      <TooltipContent>{full}</TooltipContent>
    </Tooltip>
  )
}

export { TruncatedText }
