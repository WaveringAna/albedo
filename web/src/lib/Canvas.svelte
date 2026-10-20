<script lang="ts">
  import { MiniMap, NodeResizer, SvelteFlow, type NodeTypes } from '@xyflow/svelte';
  import { ZOOM, type Board } from './board.svelte';
  import { prefs } from './prefs.svelte';
  import Dots from './Dots.svelte';
  import FlowBinder from './FlowBinder.svelte';
  import { shortcut } from './keys';
  import NoteNode from './nodes/NoteNode.svelte';
  import ReviewNode from './nodes/ReviewNode.svelte';
  import TerminalNode from './nodes/TerminalNode.svelte';
  import Tethers from './Tethers.svelte';
  import SessionNode from './nodes/SessionNode.svelte';

  // Mounted again on every tab switch (keyed on the board), so each board
  // opens on its own saved view.
  //
  // The wheel is handled here rather than by Svelte Flow, because a window's
  // contents and the canvas share the trackpad: a pinch zooms the canvas
  // anywhere, an up-down scroll over a readable window scrolls that window,
  // a sideways one over something that scrolls sideways (a diff's code, a
  // wide table) scrolls that, and every other scroll pans the canvas freely. Holding space, or the
  // middle button, drags the canvas from anywhere, over windows too; holding
  // alt (option) drags a window by any part of it, not only its title bar.
  let { board, onpalette, minimap, mapWidth }: { board: Board; onpalette: () => void; minimap: boolean; mapWidth: number } = $props();

  const nodeTypes: NodeTypes = { session: SessionNode, review: ReviewNode, terminal: TerminalNode, note: NoteNode };

  // A double-click on empty canvas leaves a note there. Holding space, a
  // double-click anywhere, over windows too, takes the view there instead.
  const JUMP_ZOOM = 0.9;
  function dblclick(event: MouseEvent) {
    const at = { x: event.clientX, y: event.clientY };
    if (hand) {
      event.stopPropagation();
      board.centreOn(at, JUMP_ZOOM);
    } else if ((event.target as HTMLElement).classList.contains('svelte-flow__pane')) board.noteAt(at);
  }
  const READABLE = 0.6;
  let element = $state<HTMLElement>();

  function scrollsItself(target: EventTarget | null, deltaY: number) {
    const scroller = (target as HTMLElement | null)?.closest<HTMLElement>('.nowheel');
    if (!scroller || board.viewport.zoom < READABLE) return false;
    // At either end a scroll still belongs to the window, so it never jumps to panning mid-read.
    return scroller.scrollHeight > scroller.clientHeight || deltaY === 0;
  }

  // The path crosses into shadow roots, so Pierre's code element counts.
  function scrollsSideways(event: WheelEvent) {
    if (board.viewport.zoom < READABLE) return false;
    for (const target of event.composedPath()) {
      if (!(target instanceof HTMLElement) || target.classList.contains('svelte-flow__node')) break;
      const overflow = getComputedStyle(target).overflowX;
      if ((overflow === 'auto' || overflow === 'scroll') && target.scrollWidth > target.clientWidth + 1) return true;
    }
    return false;
  }

  // A pinch moves a few pixels at a time, a mouse wheel's notch a hundred or
  // so (or a few lines), so a notch is one fixed step rather than a jump.
  const NOTCH = 1.1;
  function zoomFactor(event: WheelEvent) {
    const pixels = event.deltaMode === WheelEvent.DOM_DELTA_PIXEL ? event.deltaY : event.deltaY * 40;
    return Math.abs(pixels) >= 50 ? NOTCH ** -Math.sign(pixels) : Math.exp(-pixels * 0.01);
  }

  let hand = $state(false);
  let panning = $state<{ x: number; y: number } | null>(null);
  let alt = $state(false);
  let carrying = $state<{ id: string; pointer: { x: number; y: number }; from: { x: number; y: number } } | null>(null);
  // The click that ends a carry is swallowed, so letting go over a link or a
  // button presses nothing (option-click would download a link).
  let swallow = false;

  function typing(target: EventTarget | null) {
    return !!(target as HTMLElement | null)?.closest('input, textarea, select, [contenteditable]:not([contenteditable="false"])');
  }

  function keydown(event: KeyboardEvent) {
    if (event.key === 'Alt') alt = true;
    if (event.key !== ' ' || typing(event.target) || event.metaKey || event.ctrlKey || event.altKey) return;
    // Held, not typed: no scrolling the page or pressing the focused button.
    event.preventDefault();
    hand = true;
  }

  function keyup(event: KeyboardEvent) {
    if (event.key === ' ') hand = false;
    if (event.key === 'Alt') alt = false;
  }

  function grab(event: PointerEvent) {
    const frame = event.button === 0 && event.altKey && !hand ? (event.target as Element).closest<HTMLElement>('.svelte-flow__node') : null;
    const node = frame && board.nodes.find((candidate) => candidate.id === frame.dataset.id);
    if (!(event.button === 1 || (hand && event.button === 0) || node)) return;
    // Taken before Svelte Flow or a window sees it, so nothing drags, selects or autoscrolls.
    event.preventDefault();
    event.stopPropagation();
    element!.setPointerCapture(event.pointerId);
    const pointer = { x: event.clientX, y: event.clientY };
    if (node) carrying = { id: node.id, pointer, from: node.position };
    else panning = pointer;
  }

  function drag(event: PointerEvent) {
    if (carrying) {
      const { pointer, from } = carrying;
      const zoom = board.viewport.zoom;
      board.place(carrying.id, { x: from.x + (event.clientX - pointer.x) / zoom, y: from.y + (event.clientY - pointer.y) / zoom });
      return;
    }
    if (!panning) return;
    const { x, y, zoom } = board.viewport;
    board.setView({ x: x + event.clientX - panning.x, y: y + event.clientY - panning.y, zoom });
    panning = { x: event.clientX, y: event.clientY };
  }

  function release() {
    if (carrying) {
      swallow = true;
      setTimeout(() => (swallow = false));
    }
    panning = null;
    carrying = null;
  }

  function click(event: MouseEvent) {
    if (!swallow) return;
    event.preventDefault();
    event.stopPropagation();
  }

  $effect(() => {
    if (!element) return;
    const wheel = (event: WheelEvent) => {
      const rect = element!.getBoundingClientRect();
      if (event.ctrlKey || event.metaKey) {
        event.preventDefault();
        board.zoomAt(zoomFactor(event), { x: event.clientX - rect.left, y: event.clientY - rect.top });
        return;
      }
      const vertical = Math.abs(event.deltaY) >= Math.abs(event.deltaX);
      if (vertical ? scrollsItself(event.target, event.deltaY) : scrollsSideways(event)) return;
      event.preventDefault();
      const { x, y, zoom } = board.viewport;
      board.setView({ x: x - event.deltaX, y: y - event.deltaY, zoom });
    };
    element.addEventListener('wheel', wheel, { passive: false, capture: true });
    element.addEventListener('pointerdown', grab, { capture: true });
    return () => {
      element?.removeEventListener('wheel', wheel, { capture: true });
      element?.removeEventListener('pointerdown', grab, { capture: true });
    };
  });
</script>

<svelte:window onkeydown={keydown} onkeyup={keyup} onblur={() => (hand = alt = false)} />

<div
  class="canvas"
  class:hand
  class:panning={panning !== null}
  class:alt
  class:carrying={carrying !== null}
  bind:this={element}
  ondblclickcapture={dblclick}
  onclickcapture={click}
  onpointermove={drag}
  onpointerup={release}
  onpointercancel={release}
  role="presentation"
>
  <SvelteFlow
    bind:nodes={board.nodes}
    edges={board.edges}
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
    panActivationKey={null}
    nodesConnectable={false}
    proOptions={{ hideAttribution: true }}
    onmove={(_, viewport) => (board.viewport = viewport)}
  >
    {#if prefs.dots}
      <Dots gap={36} size={3} />
    {/if}
    {#if minimap}
      <MiniMap position="bottom-right" pannable zoomable={false} width={mapWidth} height={Math.round((mapWidth * 104) / 168)} nodeBorderRadius={6} bgColor="var(--surface)" nodeColor="var(--minimap-window)" maskColor="var(--minimap-mask)" />
    {/if}
    <FlowBinder {board} />
  </SvelteFlow>
  <Tethers {board} />

  {#if board.nodes.length === 0}
    <div class="empty">
      <p class="face kaomoji" aria-hidden="true">(・ω・)ﾉ</p>
      <p class="lead">an empty board</p>
      <p>open a session to start. windows can sit anywhere; pinch to zoom out and see them all. double-click to leave a note.</p>
      <button onclick={onpalette}>open a session <kbd>{shortcut('K')}</kbd></button>
    </div>
  {/if}
</div>

<style>
  .canvas {
    position: absolute;
    inset: 0;
  }
  .hand,
  .hand :global(*) {
    cursor: grab !important;
    user-select: none;
  }
  .panning,
  .panning :global(*) {
    cursor: grabbing !important;
  }
  .alt :global(.svelte-flow__node),
  .alt :global(.svelte-flow__node *),
  .carrying,
  .carrying :global(*) {
    cursor: move !important;
    user-select: none;
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
