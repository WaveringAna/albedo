<script lang="ts" module>
  export interface Item {
    key: string;
    kind: 'command' | 'session';
    label: string;
    detail?: string;
    hint?: string;
    run: () => void;
  }
</script>

<script lang="ts">
  // Opens and closes without animation: it is used many times a day and
  // should feel like part of the keyboard.
  let { placeholder, search, onclose }: { placeholder: string; search: (query: string) => Item[]; onclose: () => void } = $props();

  let query = $state('');
  let active = $state(0);
  let list = $state<HTMLElement>();
  const items = $derived(search(query));

  $effect(() => {
    query;
    active = 0;
  });

  $effect(() => {
    list?.querySelector(`[data-index="${active}"]`)?.scrollIntoView({ block: 'nearest' });
  });

  function choose(item: Item | undefined) {
    if (!item) return;
    onclose();
    item.run();
  }

  function keydown(event: KeyboardEvent) {
    const step = { ArrowDown: 1, ArrowUp: -1 }[event.key] ?? (event.ctrlKey ? { n: 1, p: -1 }[event.key] : undefined);
    if (step) {
      event.preventDefault();
      active = (active + step + items.length) % Math.max(items.length, 1);
    } else if (event.key === 'Enter') {
      event.preventDefault();
      choose(items[active]);
    } else if (event.key === 'Escape') {
      event.preventDefault();
      onclose();
    }
  }
</script>

<div class="backdrop" role="presentation" onpointerdown={(event) => event.target === event.currentTarget && onclose()}>
  <div class="palette" role="dialog" aria-label="Command palette" aria-modal="true">
    <!-- svelte-ignore a11y_autofocus -->
    <input bind:value={query} onkeydown={keydown} {placeholder} spellcheck="false" autofocus aria-controls="palette-list" aria-activedescendant={items[active] ? `palette-${active}` : undefined} />
    <ul id="palette-list" role="listbox" bind:this={list}>
      {#each items as item, index (item.key)}
        <li id="palette-{index}" role="option" aria-selected={index === active} data-index={index} class:active={index === active} onpointermove={() => (active = index)} onclick={() => choose(item)} onkeydown={() => {}}>
          <span class="label">{item.label}</span>
          {#if item.detail}<span class="detail">{item.detail}</span>{/if}
          {#if item.hint}<kbd>{item.hint}</kbd>{/if}
        </li>
      {:else}
        <li class="none">nothing matches</li>
      {/each}
    </ul>
  </div>
</div>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    z-index: 100;
    display: flex;
    justify-content: center;
    padding-top: 14vh;
    background: var(--scrim);
  }
  .palette {
    display: flex;
    flex-direction: column;
    width: min(560px, calc(100vw - 32px));
    max-height: 420px;
    overflow: hidden;
    background: var(--surface);
    border-radius: 14px;
    box-shadow: var(--shadow-lg);
  }
  input {
    flex: none;
    height: 46px;
    padding: 0 16px;
    color: var(--text);
    font: inherit;
    font-size: 14px;
    background: none;
    border: 0;
    outline: 0;
  }
  ul {
    margin: 0;
    padding: 0 6px 6px;
    overflow-y: auto;
    overscroll-behavior: contain;
    list-style: none;
    scrollbar-width: thin;
  }
  li {
    display: flex;
    align-items: center;
    gap: 10px;
    height: 34px;
    padding: 0 10px;
    font-size: 13px;
    border-radius: 7px;
    cursor: pointer;
  }
  li.active {
    background: var(--hover);
  }
  .label {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .detail {
    flex: none;
    max-width: 45%;
    overflow: hidden;
    color: var(--muted);
    font-size: 11.5px;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .none {
    color: var(--muted);
    cursor: default;
  }
</style>
