<script lang="ts">
  import { Handle, NodeResizer, Position } from '@xyflow/svelte';
  import type { Snippet } from 'svelte';
  import { SIZE } from '../board.svelte';
  import { boards } from '../boards.svelte';

  // The frame every window shares: a title bar to drag it by, a close
  // button, edges and corners that resize it, and a body that scrolls and
  // selects text instead of moving the canvas. Later views (file, diff,
  // terminal) supply only the parts.
  let { id, selected, title, meta, children }: { id: string; selected: boolean; title: string; meta?: Snippet; children: Snippet } = $props();
</script>

<NodeResizer minWidth={SIZE.minWidth} minHeight={SIZE.minHeight} lineClass="window-edge" handleClass="window-corner" />
<!-- Where the lines between a window and the views it opened meet it; nothing to grab. -->
<Handle type="target" position={Position.Left} isConnectable={false} class="tether-end" />
<Handle type="source" position={Position.Right} isConnectable={false} class="tether-end" />

<article class="window" class:selected>
  <header class="window-handle">
    <h2 {title}>{title}</h2>
    {#if meta}<span class="meta">{@render meta()}</span>{/if}
    <button class="close nodrag" aria-label="Close window" title="Close window" onclick={() => boards.board?.remove(id)}>
      <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg>
    </button>
  </header>
  <div class="body nodrag">
    {@render children()}
  </div>
</article>

<style>
  .window {
    display: flex;
    flex-direction: column;
    width: 100%;
    height: 100%;
    overflow: hidden;
    background: var(--surface);
    border-radius: 14px;
    box-shadow: var(--shadow);
    transition: box-shadow 200ms cubic-bezier(0.23, 1, 0.32, 1);
  }
  .window.selected {
    box-shadow: var(--shadow-raised);
  }
  header {
    display: flex;
    flex: none;
    align-items: center;
    gap: 10px;
    height: 42px;
    padding: 0 8px 0 16px;
    background: var(--title-bar);
    cursor: grab;
    user-select: none;
  }
  header:active {
    cursor: grabbing;
  }
  .selected h2 {
    color: var(--text);
  }
  h2 {
    flex: 1;
    min-width: 0;
    margin: 0;
    overflow: hidden;
    color: var(--muted);
    transition: color 160ms ease;
    font-size: 13px;
    font-weight: 600;
    letter-spacing: -0.01em;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .meta {
    display: flex;
    flex: none;
    align-items: center;
    gap: 10px;
    color: var(--muted);
    font-size: 12px;
  }
  .close {
    display: grid;
    place-items: center;
    width: 28px;
    height: 28px;
    padding: 0;
    color: var(--muted);
    background: none;
    border: 0;
    border-radius: 8px;
    cursor: pointer;
    transition: background-color 120ms ease, color 120ms ease;
  }
  .close:hover {
    color: var(--text);
    background: var(--hover);
  }
  .close:active {
    transform: scale(0.94);
  }
  .body {
    display: flex;
    flex: 1;
    flex-direction: column;
    min-height: 0;
    cursor: auto;
    user-select: text;
  }
</style>
