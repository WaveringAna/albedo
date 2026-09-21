import type { RenderOptions } from "ink"

// Background render ceiling, not an idle timer. Chat scroll input flushes sooner.
export const terminalRendering = {
  maxFps: 240,
  incrementalRendering: true,
} satisfies RenderOptions
