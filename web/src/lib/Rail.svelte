<script lang="ts">
  import type { Session } from './api';
  import { boards } from './boards.svelte';
  import { ago, homePath, matches, place } from './format';
  import { sessions } from './sessions.svelte';

  let { search = $bindable() }: { search?: HTMLInputElement } = $props();
  let query = $state('');

  const visible = $derived(
    sessions.list.filter((session) => !session.preferences.archived && (!query || matches(query, `${session.name} ${place(session.workspace)}`))),
  );
  const pinned = $derived(visible.filter((session) => session.preferences.pinned));
  const recent = $derived(visible.filter((session) => !session.preferences.pinned));
  const onBoard = $derived(new Set(boards.board?.nodes.map((node) => node.data.sessionId)));

  function submit(event: SubmitEvent) {
    event.preventDefault();
    if (visible[0]) boards.openSession(visible[0]);
  }
</script>

<aside>
  <form class="search" onsubmit={submit}>
    <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" stroke-width="1.4" /><path d="M10.5 10.5L14 14" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" /></svg>
    <input bind:this={search} bind:value={query} placeholder="Filter sessions" aria-label="Filter sessions" spellcheck="false" onkeydown={(event) => event.key === 'Escape' && ((query = ''), search?.blur())} />
    <kbd>/</kbd>
  </form>

  <nav>
    {#if pinned.length}
      <h3>Pinned</h3>
      {#each pinned as session (session.id)}{@render row(session)}{/each}
    {/if}
    {#if recent.length}
      <h3>Recent</h3>
      {#each recent as session (session.id)}{@render row(session)}{/each}
    {/if}
    {#if sessions.loaded && visible.length === 0}
      <p class="none">{query ? 'No session matches.' : 'No sessions yet.'}</p>
    {:else if !sessions.loaded && sessions.link === 'connecting'}
      {#each { length: 6 } as _}<div class="ghost"></div>{/each}
    {/if}
  </nav>
</aside>

{#snippet row(session: Session)}
  <button class="row" class:open={onBoard.has(session.id)} onclick={() => boards.openSession(session)} title="{session.name}\n{homePath(session.workspace)}">
    <span class="name">{session.name || 'Untitled session'}</span>
    {#if session.status?.phase === 'running'}
      <span class="when working">working</span>
    {:else}
      <span class="when">{ago(session.activity_at)}</span>
    {/if}
    <span class="where">{place(session.workspace)}</span>
  </button>
{/snippet}

<style>
  aside {
    display: flex;
    flex-direction: column;
    min-height: 0;
    padding-top: 10px;
    background: var(--rail);
  }
  .search {
    display: flex;
    align-items: center;
    gap: 8px;
    height: 30px;
    margin: 0 10px 8px;
    padding: 0 6px 0 9px;
    color: var(--muted);
    background: var(--field);
    border-radius: 8px;
    transition: box-shadow 120ms ease;
  }
  .search:focus-within {
    box-shadow: 0 0 0 2px var(--focus-ring);
  }
  .search input {
    flex: 1;
    min-width: 0;
    padding: 0;
    color: var(--text);
    font: inherit;
    font-size: 12.5px;
    background: none;
    border: 0;
    outline: 0;
  }
  .search:focus-within kbd {
    visibility: hidden;
  }
  nav {
    flex: 1;
    min-height: 0;
    padding: 0 6px 12px;
    overflow-y: auto;
    overscroll-behavior: contain;
    scrollbar-width: thin;
  }
  h3 {
    margin: 16px 10px 6px;
    color: var(--muted);
    font-size: 12px;
    font-weight: 560;
  }
  .row {
    display: grid;
    grid-template-columns: 1fr auto;
    grid-template-areas: 'name when' 'where where';
    align-items: baseline;
    gap: 1px 10px;
    width: 100%;
    padding: 7px 10px;
    color: var(--text);
    font: inherit;
    text-align: left;
    background: none;
    border: 0;
    border-radius: 7px;
    cursor: pointer;
    transition: background-color 100ms ease;
  }
  .row:hover {
    background: var(--hover);
  }
  .row.open {
    background: var(--selected);
  }
  .name {
    grid-area: name;
    overflow: hidden;
    font-size: 12.5px;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .when {
    grid-area: when;
    color: var(--muted);
    font-size: 11.5px;
    font-variant-numeric: tabular-nums;
  }
  .where {
    grid-area: where;
    overflow: hidden;
    color: var(--muted);
    font-size: 12px;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .none {
    margin: 16px 8px;
    color: var(--muted);
    font-size: 12.5px;
  }
  .ghost {
    height: 38px;
    margin: 2px 8px 6px;
    background: var(--hover);
    border-radius: 7px;
  }
</style>
