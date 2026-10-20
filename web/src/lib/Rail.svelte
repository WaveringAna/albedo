<script lang="ts">
  import type { Session } from './api';
  import { boards } from './boards.svelte';
  import { ago, homePath, matches, place } from './format';
  import { busy } from './live.svelte';
  import LiveFace from './LiveFace.svelte';
  import { sessions } from './sessions.svelte';

  let { search = $bindable() }: { search?: HTMLInputElement } = $props();
  let query = $state('');

  const visible = $derived(
    sessions.list.filter((session) => !session.preferences.archived && (!query || matches(query, `${session.name} ${place(session.workspace)}`))),
  );
  // Grouped as the terminal groups them: pinned, then by when they last moved.
  const DAY = 86_400_000;
  const sections = $derived.by(() => {
    const midnight = new Date().setHours(0, 0, 0, 0);
    const when = (session: Session) => Date.parse(session.activity_at ?? '') || 0;
    const named: [string, (session: Session) => boolean][] = [
      ['pinned', (session) => session.preferences.pinned],
      ['today', (session) => when(session) >= midnight],
      ['this week', (session) => when(session) >= midnight - 6 * DAY],
      ['earlier', () => true],
    ];
    const left = [...visible];
    return named
      .map(([label, belongs]) => {
        const rows = left.filter(belongs);
        for (const row of rows) left.splice(left.indexOf(row), 1);
        return { label, rows };
      })
      .filter((section) => section.rows.length);
  });
  const onBoard = $derived(new Set(boards.board?.nodes.flatMap((node) => (node.type === 'note' ? [] : [node.data.sessionId]))));

  function submit(event: SubmitEvent) {
    event.preventDefault();
    if (visible[0]) boards.openSession(visible[0]);
  }
</script>

<aside>
  <form class="search" onsubmit={submit}>
    <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" stroke-width="1.4" /><path d="M10.5 10.5L14 14" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" /></svg>
    <input bind:this={search} bind:value={query} placeholder="filter sessions" aria-label="Filter sessions" spellcheck="false" onkeydown={(event) => event.key === 'Escape' && ((query = ''), search?.blur())} />
    <kbd>/</kbd>
  </form>

  <nav>
    {#each sections as section (section.label)}
      <h3>{section.label} <span class="count">{section.rows.length}</span></h3>
      {#each section.rows as session (session.id)}{@render row(session)}{/each}
    {/each}
    {#if sessions.loaded && visible.length === 0}
      <p class="none">{query ? 'nothing matches (・_・ )' : 'no sessions yet (・ω・)ﾉ'}</p>
    {:else if !sessions.loaded && sessions.link === 'connecting'}
      {#each { length: 6 } as _}<div class="ghost"></div>{/each}
    {/if}
  </nav>
</aside>

{#snippet row(session: Session)}
  <button class="row" class:open={onBoard.has(session.id)} onclick={() => boards.openSession(session)} title="{session.name}\n{homePath(session.workspace)}">
    <span class="name">{#if session.preferences.pinned}<span class="star" aria-label="pinned">★</span>{/if}{session.name || 'untitled session'}</span>
    {#if busy(session)}
      <span class="when"><LiveFace {session} /></span>
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
    font-weight: 600;
  }
  .count {
    color: var(--faint);
    font-weight: 400;
  }
  .star {
    margin-right: 5px;
    color: var(--agent);
    font-size: 11px;
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
