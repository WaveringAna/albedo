<script lang="ts">
  import type { Session } from './api';
  import { clock, liveFrames, liveMood } from './live.svelte';

  // The face a busy session makes, animated for what it is doing now. The
  // widest frame sits invisibly under the current one, so the face holds its
  // width as it moves and nothing beside it shifts.
  let { session, label = false }: { session: Session | undefined; label?: boolean } = $props();
  const mood = $derived(liveMood(session));
  const set = $derived(session ? liveFrames(session.id, mood) : []);

  $effect(() => clock.use());
</script>

{#if session}
  <span class="live" title={mood}>
    {#if label}<span class="word">{mood}</span>{/if}
    <span class="face kaomoji">
      {#each set as frame, index (index)}<span class="sizer" aria-hidden="true">{frame}</span>{/each}
      <span class="now">{set[clock.tick % set.length]}</span>
    </span>
  </span>
{/if}

<style>
  .live {
    display: inline-flex;
    align-items: baseline;
    gap: 6px;
    color: var(--agent);
    white-space: nowrap;
  }
  .word {
    color: var(--muted);
  }
  .face {
    display: inline-grid;
    font-weight: 500;
  }
  .sizer,
  .now {
    grid-area: 1 / 1;
  }
  .sizer {
    visibility: hidden;
  }
</style>
