<script lang="ts">
  import type { Snippet } from 'svelte';

  // A title-bar icon that lists things: the session's background jobs, the
  // artifacts it made. The list closes on a pick, a click elsewhere or Escape;
  // `up` opens it above the icon, for the phone's composer.
  let {
    label,
    count = 0,
    live = false,
    up = false,
    open = $bindable(false),
    icon,
    children,
  }: { label: string; count?: number; live?: boolean; up?: boolean; open?: boolean; icon: Snippet; children: Snippet } = $props();
  let element = $state<HTMLElement>();

  $effect(() => {
    if (!open) return;
    const away = (event: Event) => event.target instanceof Node && !element?.contains(event.target) && (open = false);
    const escape = (event: KeyboardEvent) => event.key === 'Escape' && (open = false);
    addEventListener('pointerdown', away, true);
    addEventListener('keydown', escape);
    return () => {
      removeEventListener('pointerdown', away, true);
      removeEventListener('keydown', escape);
    };
  });
</script>

<span class="menu nodrag" bind:this={element}>
  <button class="icon" class:live aria-expanded={open} aria-label={label} title={label} onclick={() => (open = !open)}>
    {@render icon()}
    {#if count}<span class="count">{count}</span>{/if}
  </button>
  {#if open}
    <ul class="list nowheel" class:up>
      {@render children()}
    </ul>
  {/if}
</span>

<style>
  .menu {
    position: relative;
    display: inline-flex;
  }
  .icon {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    height: 26px;
    padding: 0 7px;
    color: var(--muted);
    font: inherit;
    font-size: 12px;
    background: none;
    border: 0;
    border-radius: 8px;
    cursor: pointer;
    transition: background-color 120ms ease, color 120ms ease;
  }
  .icon:hover,
  .icon[aria-expanded='true'] {
    color: var(--text);
    background: var(--hover);
  }
  .icon.live {
    color: var(--accent);
  }
  .count {
    font-variant-numeric: tabular-nums;
  }
  .list {
    position: absolute;
    top: calc(100% + 6px);
    right: 0;
    z-index: 5;
    width: min(340px, 80vw);
    max-height: 260px;
    margin: 0;
    padding: 4px;
    overflow-y: auto;
    list-style: none;
    background: var(--surface);
    border-radius: 12px;
    box-shadow: var(--shadow-raised);
  }
  .list.up {
    top: auto;
    bottom: calc(100% + 6px);
    right: auto;
    left: 0;
  }
  .list :global(li > button) {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto auto;
    align-items: baseline;
    gap: 10px;
    width: 100%;
    padding: 7px 10px;
    color: var(--text);
    font: inherit;
    font-size: 12.5px;
    text-align: left;
    background: none;
    border: 0;
    border-radius: 8px;
    cursor: pointer;
  }
  .list :global(li > button:hover) {
    background: var(--hover);
  }
  .list :global(.when) {
    color: var(--muted);
    font-size: 11.5px;
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }
</style>
