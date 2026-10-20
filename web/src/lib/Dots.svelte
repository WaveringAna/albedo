<script lang="ts">
  import { useViewport } from '@xyflow/svelte';

  // The canvas's dots. Zooming out, they merge rather than fade: one tile
  // twice the spacing holds a dot that stays and three that dissolve into it
  // between 100% and 50%, where the grid that is left looks as it did at
  // 100%, and the same happens again a level up. A dot keeps its size on
  // screen whatever the zoom.
  let { gap, size }: { gap: number; size: number } = $props();
  const id = $props.id();
  const viewport = useViewport();

  const level = $derived(Math.max(0, Math.log2(1 / viewport.current.zoom)));
  /** The spacing on screen of every dot, merging ones included. */
  const step = $derived(gap * 2 ** Math.floor(level) * viewport.current.zoom);
  const merging = $derived(1 - (level % 1));
  const r = $derived(size / 2);
</script>

<svg class="svelte-flow__background svelte-flow__container" aria-hidden="true">
  <pattern
    id="dots-{id}"
    x={viewport.current.x % (step * 2)}
    y={viewport.current.y % (step * 2)}
    width={step * 2}
    height={step * 2}
    patternUnits="userSpaceOnUse"
    patternTransform="translate(-{r},-{r})"
  >
    <circle cx={r} cy={r} {r} />
    <circle cx={step + r} cy={r} {r} opacity={merging} />
    <circle cx={r} cy={step + r} {r} opacity={merging} />
    <circle cx={step + r} cy={step + r} {r} opacity={merging} />
  </pattern>
  <rect width="100%" height="100%" fill="url(#dots-{id})" />
</svg>

<style>
  circle {
    fill: var(--dots);
  }
</style>
