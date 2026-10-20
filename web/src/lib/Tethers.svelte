<script lang="ts">
  import { anchorPoint, pick, targetBox } from './anchors';
  import type { Board, NoteWindow } from './board.svelte';
  import { tying } from './tie.svelte';

  // The lines from notes to what they are about. Targets live inside windows
  // that scroll and redraw on their own, so the lines are measured in screen
  // space every frame while any note is tied, and drawn over the canvas.
  let { board }: { board: Board } = $props();
  let element = $state<SVGSVGElement>();
  // Each tie is a line and, where its target is a passage, a tint over it,
  // so a note and what it is about read as one even with several on screen.
  // The note in hand (selected or under the pointer) draws strongest.
  let paths = $state<{ id: string; d: string; sent: boolean; lit: boolean; box: { x: number; y: number; width: number; height: number } | null }[]>([]);
  let preview = $state<string | null>(null);
  // While a tie is drawn, what it would land on.
  let landing = $state<{ x: number; y: number; width: number; height: number; window: boolean } | null>(null);

  // Which note the pointer is over, read from the canvas rather than asked of each note.
  let hovered = $state<string | null>(null);
  $effect(() => {
    const over = (event: PointerEvent) => {
      hovered = (event.target as Element | null)?.closest<HTMLElement>('.svelte-flow__node-note')?.dataset.id ?? null;
    };
    document.addEventListener('pointerover', over);
    return () => document.removeEventListener('pointerover', over);
  });

  const tied = $derived(board.nodes.filter((node): node is NoteWindow => node.type === 'note' && !!node.data.target));

  function curve(a: { x: number; y: number }, b: { x: number; y: number }) {
    const bend = Math.max(24, Math.abs(b.x - a.x) / 2);
    const direction = b.x >= a.x ? 1 : -1;
    return `M${a.x} ${a.y} C${a.x + bend * direction} ${a.y} ${b.x - bend * direction} ${b.y} ${b.x} ${b.y}`;
  }

  function noteEnd(id: string, toward: number) {
    const rect = document.querySelector(`.svelte-flow__node[data-id="${CSS.escape(id)}"]`)?.getBoundingClientRect();
    if (!rect) return null;
    return { x: toward < rect.left + rect.width / 2 ? rect.left : rect.right, y: rect.top + 16 };
  }

  $effect(() => {
    if (!element || (!tied.length && !tying.note)) {
      paths = [];
      preview = null;
      landing = null;
      return;
    }
    let frame = 0;
    const draw = () => {
      const origin = element!.getBoundingClientRect();
      const local = (point: { x: number; y: number }) => ({ x: point.x - origin.left, y: point.y - origin.top });
      const next: typeof paths = [];
      for (const note of tied) {
        const rect = document.querySelector(`.svelte-flow__node[data-id="${CSS.escape(note.id)}"]`)?.getBoundingClientRect();
        if (!rect) continue;
        const centre = { x: rect.left + rect.width / 2, y: rect.top + 16 };
        const box = targetBox(note.data.target!);
        // A visible passage takes the line right to its own edge.
        const point = anchorPoint(note.data.target!, centre);
        const end = point && box ? { x: centre.x > box.left + box.width / 2 ? box.right : box.left, y: Math.min(box.bottom - 2, Math.max(box.top + 2, point.y)) } : point;
        const start = end && noteEnd(note.id, end.x);
        const lit = !!note.selected || hovered === note.id;
        if (end && start)
          next.push({ id: note.id, d: curve(local(start), local(end)), sent: !!note.data.sent, lit, box: box && { x: box.left - origin.left, y: box.top - origin.top, width: box.width, height: box.height } });
      }
      paths = next;
      if (tying.note && !board.nodes.some((node) => node.id === tying.note)) tying.note = null;
      if (tying.note) {
        const start = noteEnd(tying.note, tying.x);
        preview = start ? curve(local(start), local({ x: tying.x, y: tying.y })) : null;
        const found = pick(tying.x, tying.y);
        const rect = found?.element.getBoundingClientRect();
        landing = rect ? { x: rect.left - origin.left, y: rect.top - origin.top, width: rect.width, height: rect.height, window: found!.target.kind === 'window' } : null;
      } else [preview, landing] = [null, null];
      frame = requestAnimationFrame(draw);
    };
    draw();
    return () => cancelAnimationFrame(frame);
  });
</script>

<svg class="tethers" bind:this={element} aria-hidden="true">
  {#each paths as path (path.id)}
    {#if path.box}<rect class="passage" class:lit={path.lit} class:sent={path.sent} x={path.box.x} y={path.box.y} width={path.box.width} height={path.box.height} rx="3" />{/if}
    <path d={path.d} class:sent={path.sent} class:lit={path.lit} />
    <circle cx={path.d.split(' ').at(-2)} cy={path.d.split(' ').at(-1)} r={path.lit ? 3.5 : 2.5} class:sent={path.sent} />
  {/each}
  {#if landing}<rect class="landing" class:whole={landing.window} x={landing.x - 2} y={landing.y - 1} width={landing.width + 4} height={landing.height + 2} rx="6" />{/if}
  {#if preview}<path d={preview} class="preview" />{/if}
</svg>

<style>
  .tethers {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    overflow: visible;
    pointer-events: none;
    z-index: 4;
  }
  path {
    fill: none;
    stroke: color-mix(in oklab, var(--accent) 55%, transparent);
    stroke-width: 1.5;
  }
  path.lit {
    stroke: var(--accent);
    stroke-width: 2.25;
  }
  .passage {
    fill: color-mix(in oklab, var(--accent) 10%, transparent);
    stroke: color-mix(in oklab, var(--accent) 35%, transparent);
    stroke-width: 1;
  }
  .passage.lit {
    fill: color-mix(in oklab, var(--accent) 18%, transparent);
    stroke: var(--accent);
  }
  circle {
    fill: var(--accent);
  }
  .sent {
    opacity: 0.35;
  }
  .landing {
    fill: color-mix(in oklab, var(--accent) 12%, transparent);
    stroke: color-mix(in oklab, var(--accent) 70%, transparent);
    stroke-width: 1.5;
  }
  .landing.whole {
    fill: none;
    rx: 12px;
  }
  .preview {
    stroke: var(--accent);
    stroke-dasharray: none;
  }
</style>
