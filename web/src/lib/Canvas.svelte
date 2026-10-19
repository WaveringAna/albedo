<script lang="ts">
  import { Background, BackgroundVariant, MiniMap, NodeResizer, SvelteFlow, type NodeTypes } from '@xyflow/svelte';
  import { ZOOM, type Board } from './board.svelte';
  import { prefs } from './prefs.svelte';
  import FlowBinder from './FlowBinder.svelte';
  import { shortcut } from './keys';
  import SessionNode from './nodes/SessionNode.svelte';

  // Mounted again on every tab switch (keyed on the board), so each board
  // opens on its own saved view.
  //
  // The wheel is handled here rather than by Svelte Flow, because a window's
  // contents and the canvas share the trackpad: a pinch zooms the canvas
  // anywhere, an up-down scroll over a readable window scrolls that window,
  // and every other scroll pans the canvas freely.
  let { board, onpalette, minimap }: { board: Board; onpalette: () => void; minimap: boolean } = $props();

  const nodeTypes: NodeTypes = { session: SessionNode };
  const READABLE = 0.6;
  let element = $state<HTMLElement>();
  // The dots fade out as the view zooms out, before they crowd into a texture.
  const zoom = $derived(board.viewport.zoom);

  function scrollsItself(target: EventTarget | null, deltaY: number) {
    const scroller = (target as HTMLElement | null)?.closest<HTMLElement>('.nowheel');
    if (!scroller || board.viewport.zoom < READABLE) return false;
    // At either end a scroll still belongs to the window, so it never jumps to panning mid-read.
    return scroller.scrollHeight > scroller.clientHeight || deltaY === 0;
  }

  $effect(() => {
    if (!element) return;
    const wheel = (event: WheelEvent) => {
      const rect = element!.getBoundingClientRect();
      if (event.ctrlKey || event.metaKey) {
        event.preventDefault();
        board.zoomAt(Math.exp(-event.deltaY * 0.01), { x: event.clientX - rect.left, y: event.clientY - rect.top });
        return;
      }
      const vertical = Math.abs(event.deltaY) >= Math.abs(event.deltaX);
      if (vertical && scrollsItself(event.target, event.deltaY)) return;
      event.preventDefault();
      const { x, y, zoom } = board.viewport;
      board.setView({ x: x - event.deltaX, y: y - event.deltaY, zoom });
    };
    element.addEventListener('wheel', wheel, { passive: false, capture: true });
    return () => element?.removeEventListener('wheel', wheel, { capture: true });
  });
</script>

<div class="canvas" bind:this={element} style:--dots-opacity={Math.min(1, (zoom - 0.5) * 4)}>
  <SvelteFlow
    bind:nodes={board.nodes}
    {nodeTypes}
    colorMode={prefs.resolved}
    initialViewport={board.viewport}
    minZoom={ZOOM.min}
    maxZoom={ZOOM.max}
    panOnDrag
    panOnScroll={false}
    zoomOnScroll={false}
    zoomOnPinch={false}
    zoomOnDoubleClick={false}
    deleteKey={null}
    nodesConnectable={false}
    proOptions={{ hideAttribution: true }}
    onmove={(_, viewport) => (board.viewport = viewport)}
  >
    {#if prefs.dots && zoom >= 0.5}
      <Background variant={BackgroundVariant.Dots} gap={28} size={1.6} />
    {/if}
    {#if minimap}
      <MiniMap position="bottom-right" pannable zoomable={false} width={168} height={104} nodeBorderRadius={6} bgColor="var(--surface)" nodeColor="var(--minimap-window)" maskColor="var(--minimap-mask)" />
    {/if}
    <FlowBinder {board} />
  </SvelteFlow>

  {#if board.nodes.length === 0}
    <div class="empty">
      <p class="face kaomoji" aria-hidden="true">(・ω・)ﾉ</p>
      <p class="lead">an empty board</p>
      <p>open a session to start. windows can sit anywhere; pinch to zoom out and see them all.</p>
      <button onclick={onpalette}>open a session <kbd>{shortcut('K')}</kbd></button>
    </div>
  {/if}
</div>

<style>
  .canvas {
    position: absolute;
    inset: 0;
  }
  .empty {
    position: absolute;
    inset: 0;
    display: grid;
    place-content: center;
    justify-items: center;
    gap: 6px;
    text-align: center;
    pointer-events: none;
  }
  .empty p {
    max-width: 34ch;
    margin: 0;
    color: var(--muted);
    font-size: 13px;
    text-wrap: balance;
  }
  .empty .face {
    margin-bottom: 4px;
    color: var(--agent);
    font-size: 22px;
  }
  .empty .lead {
    color: var(--text);
    font-size: 15px;
    font-weight: 560;
  }
  .empty button {
    display: flex;
    align-items: center;
    gap: 10px;
    height: 34px;
    margin-top: 12px;
    padding: 0 8px 0 14px;
    color: var(--text);
    font: inherit;
    font-size: 13px;
    background: var(--surface);
    border: 0;
    border-radius: 10px;
    box-shadow: var(--shadow);
    cursor: pointer;
    pointer-events: auto;
    transition: transform 120ms ease-out, box-shadow 160ms ease;
  }
  .empty button:hover {
    box-shadow: var(--shadow-raised);
  }
  .empty button:active {
    transform: scale(0.97);
  }
</style>
