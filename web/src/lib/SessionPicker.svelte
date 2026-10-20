<script lang="ts">
  import type { Session } from './api';
  import { boards } from './boards.svelte';
  import { ago, matches, place } from './format';
  import { busy } from './live.svelte';
  import LiveFace from './LiveFace.svelte';
  import { sessions } from './sessions.svelte';

  // The phone's way to pick a session: the few you come back to as tiles
  // (pinned, then the ones opened most, then today's), everything else as a
  // list under them, and the search at the bottom where the thumb is. While
  // searching it is all list.
  let { onnew }: { onnew?: () => void } = $props();
  let query = $state('');

  const TILES = 6;
  const OFTEN = 3;
  const shown = $derived(sessions.list.filter((session) => !session.preferences.archived));
  const found = $derived(query ? shown.filter((session) => matches(query, `${session.name} ${place(session.workspace)}`)) : []);
  const tiles = $derived.by(() => {
    const midnight = new Date().setHours(0, 0, 0, 0);
    const pinned = shown.filter((session) => session.preferences.pinned);
    const often = shown
      .filter((session) => (session.preferences.opens ?? 0) >= OFTEN)
      .sort((a, b) => (b.preferences.opens ?? 0) - (a.preferences.opens ?? 0));
    const today = shown.filter((session) => (Date.parse(session.activity_at ?? '') || 0) >= midnight);
    return [...new Set([...pinned, ...often, ...today])].slice(0, TILES);
  });
  const rest = $derived(shown.filter((session) => !tiles.includes(session)));
</script>

<div class="sessions">
  <div class="scroll">
    {#if query}
      {#each found as session (session.id)}{@render row(session)}{/each}
      {#if !found.length}<p class="none">nothing matches (・_・ )</p>{/if}
    {:else}
      {#if tiles.length}
        <div class="tiles">
          {#each tiles as session (session.id)}
            <button class="tile" onclick={() => boards.openSession(session)}>
              <span class="name">{session.name || 'untitled session'}</span>
              <span class="foot">
                <span class="where">{place(session.workspace)}</span>
                {#if busy(session)}<LiveFace {session} />{:else}<span class="when">{ago(session.activity_at)}</span>{/if}
              </span>
            </button>
          {/each}
        </div>
      {/if}
      {#if tiles.length && rest.length}<hr class="dots" />{/if}
      {#each rest as session (session.id)}{@render row(session)}{/each}
      {#if sessions.loaded && !shown.length}<p class="none">no sessions yet (・ω・)ﾉ</p>{/if}
    {/if}
  </div>

  <div class="bottom">
    <label class="search">
      <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true"><circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" stroke-width="1.4" /><path d="M10.5 10.5L14 14" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" /></svg>
      <input bind:value={query} placeholder="search" aria-label="search sessions" spellcheck="false" autocomplete="off" enterkeyhint="go" onkeydown={(event) => event.key === 'Enter' && found[0] && boards.openSession(found[0])} />
    </label>
    {#if onnew}
      <button class="new" aria-label="new session" onclick={onnew}>
        <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="M8 3.5v9M3.5 8h9" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" /></svg>
      </button>
    {/if}
  </div>
</div>

{#snippet row(session: Session)}
  <button class="row" onclick={() => boards.openSession(session)}>
    <span class="name">{session.name || 'untitled session'}</span>
    {#if busy(session)}<LiveFace {session} />{:else}<span class="when">{ago(session.activity_at)}</span>{/if}
  </button>
{/snippet}

<style>
  .sessions {
    display: flex;
    flex: 1;
    min-height: 0;
    flex-direction: column;
  }
  .scroll {
    flex: 1;
    min-height: 0;
    padding: 4px 12px 12px;
    overflow-y: auto;
    overscroll-behavior: contain;
  }
  .tiles {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 8px;
    margin-bottom: 14px;
  }
  .tile {
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    gap: 10px;
    min-width: 0;
    min-height: 76px;
    padding: 12px;
    color: var(--text);
    font: inherit;
    text-align: left;
    background: var(--well);
    border: 0;
    border-radius: 14px;
    cursor: pointer;
  }
  /* Pressing lays a step over the tile or row's own tone, so it never reads as a stripe. */
  .tile:active,
  .row:active {
    background-image: linear-gradient(var(--selected), var(--selected));
  }
  .tile .name {
    display: -webkit-box;
    overflow: hidden;
    font-size: 14.5px;
    line-height: 1.3;
    -webkit-line-clamp: 2;
    line-clamp: 2;
    -webkit-box-orient: vertical;
  }
  .foot {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 8px;
    color: var(--faint);
    font-size: 12px;
  }
  .where {
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .when {
    flex: none;
    color: var(--faint);
    font-size: 12px;
  }
  .row {
    display: flex;
    align-items: baseline;
    gap: 12px;
    width: 100%;
    padding: 11px 10px;
    color: var(--text);
    font: inherit;
    font-size: 15px;
    text-align: left;
    background: none;
    border: 0;
    border-radius: 14px;
    cursor: pointer;
  }
  /* Every other row on a softer step of the tiles' tone, so stripes don't read
     as tiles; three dots under the tiles. */
  .row:nth-of-type(odd) {
    background-color: color-mix(in oklab, var(--well) 45%, transparent);
  }
  .dots {
    width: 36px;
    height: 6px;
    margin: 0 auto 14px;
    background: radial-gradient(circle, color-mix(in oklab, var(--text) 22%, transparent) 2.5px, transparent 3px) 0 0 / 12px 6px repeat-x;
    border: 0;
  }
  .row .name {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .none {
    margin: 24px 0;
    color: var(--muted);
    font-size: 14px;
    text-align: center;
  }
  /* The search sits on its own step of tone, so it never reads as one more row. */
  .bottom {
    display: flex;
    gap: 8px;
    padding: 10px 12px;
    background: var(--bg);
    border-radius: 18px 18px 0 0;
  }
  .search {
    display: flex;
    flex: 1;
    align-items: center;
    gap: 8px;
    height: 46px;
    padding: 0 16px;
    color: var(--muted);
    background: var(--field);
    border-radius: 23px;
  }
  .search input {
    flex: 1;
    min-width: 0;
    color: var(--text);
    font: inherit;
    /* 16px keeps iOS from zooming in on focus. */
    font-size: 16px;
    background: none;
    border: 0;
    outline: 0;
  }
  .new {
    display: grid;
    flex: none;
    place-items: center;
    width: 46px;
    height: 46px;
    padding: 0;
    color: var(--accent);
    background: var(--field);
    border: 0;
    border-radius: 23px;
    cursor: pointer;
  }
</style>
