<script lang="ts" module>
  const KINDS = ['grab', 'move', 'scroll', 'click'] as const;
  export type Kind = (typeof KINDS)[number];
  /** Whether a part of a hint is drawn here rather than written. */
  export const drawn = (part: string): part is Kind => (KINDS as readonly string[]).includes(part);
</script>

<script lang="ts">
  // The mouse gesture that goes with a key in a hint: a grab (panning's
  // cursor), a move, a scroll (a mouse, its wheel) or a click.
  //
  // The drawings are Lucide's (hand-grab, move, mouse, mouse-pointer-click),
  // https://lucide.dev, ISC License, Copyright (c) 2026
  // Lucide Icons and Contributors; see THIRD_PARTY_NOTICES.md.
  let { kind }: { kind: Kind } = $props();
</script>

<svg viewBox="0 0 24 24" width="14" height="14" aria-hidden="true">
  {#if kind === 'grab'}
    <path d="M18 11.5V9a2 2 0 0 0-2-2a2 2 0 0 0-2 2v1.4" />
    <path d="M14 10V8a2 2 0 0 0-2-2a2 2 0 0 0-2 2v2" />
    <path d="M10 9.9V9a2 2 0 0 0-2-2a2 2 0 0 0-2 2v5" />
    <path d="M6 14a2 2 0 0 0-2-2a2 2 0 0 0-2 2" />
    <path d="M18 11a2 2 0 1 1 4 0v3a8 8 0 0 1-8 8h-4a8 8 0 0 1-8-8 2 2 0 1 1 4 0" />
  {:else if kind === 'move'}
    <path d="M12 2v20M2 12h20M15 19l-3 3-3-3M19 9l3 3-3 3M5 9l-3 3 3 3M9 5l3-3 3 3" />
  {:else if kind === 'scroll'}
    <rect x="5" y="2" width="14" height="20" rx="7" />
    <path d="M12 6v4" />
  {:else}
    <path d="M14 4.1 12 6M5.1 8l-2.9-.8M6 12l-1.9 2M7.2 2.2 8 5.1" />
    <path d="M9.037 9.69a.498.498 0 0 1 .653-.653l11 4.5a.5.5 0 0 1-.074.949l-4.349 1.041a1 1 0 0 0-.74.739l-1.04 4.35a.5.5 0 0 1-.95.074z" />
  {/if}
</svg>

<style>
  svg {
    fill: none;
    stroke: currentColor;
    stroke-width: 2;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
</style>
