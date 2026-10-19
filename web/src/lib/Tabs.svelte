<script lang="ts">
  import { boards } from './boards.svelte';

  let dragging = $state<string | null>(null);

  function finish(event: Event & { currentTarget: HTMLInputElement }, keep: boolean) {
    if (boards.renaming && keep) boards.rename(boards.renaming, event.currentTarget.value);
    boards.renaming = null;
  }

  function select(input: HTMLInputElement) {
    input.select();
  }
</script>

<div class="tabs" role="tablist" aria-label="Boards">
  {#each boards.tabs as tab (tab.id)}
    <div
      class="tab"
      class:active={tab.id === boards.active}
      class:dragging={tab.id === dragging}
      role="tab"
      tabindex={tab.id === boards.active ? 0 : -1}
      aria-selected={tab.id === boards.active}
      title="{tab.name} · double-click to rename"
      draggable={boards.renaming !== tab.id}
      ondragstart={(event) => {
        dragging = tab.id;
        event.dataTransfer?.setData('text/plain', tab.name);
      }}
      ondragover={(event) => {
        if (!dragging) return;
        event.preventDefault();
        boards.move(dragging, tab.id);
      }}
      ondragend={() => (dragging = null)}
      onclick={() => (boards.active = tab.id)}
      ondblclick={() => (boards.renaming = tab.id)}
      onauxclick={(event) => event.button === 1 && boards.close(tab.id)}
      onkeydown={(event) => {
        if (event.key === 'Enter' || event.key === ' ') boards.active = tab.id;
        else if (event.key === 'F2') boards.renaming = tab.id;
      }}
    >
      {#if boards.renaming === tab.id}
        <!-- svelte-ignore a11y_autofocus -->
        <input
          class="rename"
          value={tab.name}
          aria-label="Board name"
          autofocus
          use:select
          onblur={(event) => finish(event, true)}
          onkeydown={(event) => {
            event.stopPropagation();
            if (event.key === 'Enter') event.currentTarget.blur();
            else if (event.key === 'Escape') finish(event, false);
          }}
        />
      {:else}
        <span class="label">{tab.name}</span>
      {/if}
      {#if boards.tabs.length > 1}
        <button class="close" aria-label="Close {tab.name}" title="Close tab (the board is kept)" onclick={(event) => (event.stopPropagation(), boards.close(tab.id))}>
          <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg>
        </button>
      {/if}
    </div>
  {/each}
  <button class="add" aria-label="New board" title="New board" onclick={() => boards.create()}>
    <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path d="M8 3.5v9M3.5 8h9" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg>
  </button>
</div>

<style>
  .tabs {
    display: flex;
    align-items: flex-end;
    gap: 2px;
    min-width: 0;
    height: 100%;
    padding-top: 6px;
    overflow-x: auto;
    overscroll-behavior: contain;
    scrollbar-width: none;
  }
  .tab {
    position: relative;
    display: flex;
    flex: none;
    align-items: center;
    gap: 7px;
    max-width: 220px;
    height: 100%;
    padding: 0 6px 0 12px;
    color: var(--muted);
    font-size: 12.5px;
    border-radius: 8px 8px 0 0;
    cursor: default;
    user-select: none;
    transition: background-color 100ms ease, color 100ms ease;
  }
  .tab:only-of-type {
    padding-right: 12px;
  }
  .tab:hover {
    color: var(--text);
    background: var(--hover);
  }
  .tab.active {
    color: var(--text);
    background: var(--bg);
  }
  .tab.dragging {
    opacity: 0.5;
  }
  .label {
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .rename {
    width: 14ch;
    padding: 1px 4px;
    margin: 0 -5px;
    color: var(--text);
    font: inherit;
    background: var(--surface);
    border: 0;
    border-radius: 5px;
    box-shadow: 0 0 0 2px var(--focus-ring);
    outline: 0;
  }
  .close,
  .add {
    display: grid;
    flex: none;
    place-items: center;
    padding: 0;
    color: var(--muted);
    background: none;
    border: 0;
    border-radius: 5px;
    cursor: pointer;
    transition: background-color 100ms ease, color 100ms ease;
  }
  .close {
    width: 20px;
    height: 20px;
    opacity: 0;
  }
  .tab:hover .close,
  .tab.active .close,
  .close:focus-visible {
    opacity: 1;
  }
  .add {
    align-self: center;
    width: 26px;
    height: 26px;
    margin: 3px 0 0 4px;
  }
  .close:hover,
  .add:hover {
    color: var(--text);
    background: var(--hover);
  }
</style>
