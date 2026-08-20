"use client"

import { Slider as SliderPrimitive } from "@base-ui/react/slider"
import * as React from "react"

import { cn } from "@/lib/utils"

// One value, not a range: that is all this app asks a slider for, and the
// single-value shape keeps callers free of tuple handling.
type SliderProps = Omit<
  React.ComponentProps<typeof SliderPrimitive.Root>,
  "value" | "defaultValue" | "onValueChange" | "onValueCommitted"
> & {
  value?: number
  defaultValue?: number
  onValueChange?: (value: number) => void
  onValueCommitted?: (value: number) => void
}

function Slider({
  className,
  "aria-label": ariaLabel,
  ...props
}: SliderProps) {
  return (
    <SliderPrimitive.Root
      data-slot="slider"
      className={cn("w-full", className)}
      {...props}
    >
      <SliderPrimitive.Control className="flex h-8 w-full touch-none items-center select-none data-disabled:opacity-50">
        <SliderPrimitive.Track className="h-1.5 w-full rounded-full bg-muted">
          <SliderPrimitive.Indicator className="h-full rounded-full bg-primary" />
          <SliderPrimitive.Thumb
            aria-label={ariaLabel}
            className="size-4 rounded-full border border-primary bg-background shadow-sm outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50"
          />
        </SliderPrimitive.Track>
      </SliderPrimitive.Control>
    </SliderPrimitive.Root>
  )
}

export { Slider }
