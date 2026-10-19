<script lang="ts">
  import type { Session } from './api';
  import { clock, liveFace, liveMood } from './live.svelte';

  // The face a running session makes, animated: thinking, working or
  // responding, from what its activity says right now.
  let { session, label = false }: { session: Session | undefined; label?: boolean } = $props();
  const mood = $derived(liveMood(session));

  $effect(() => clock.use());
</script>

{#if session}
  <span class="live" title={mood}>
    {#if label}<span class="word">{mood}</span>{/if}
    <span class="face kaomoji">{liveFace(session.id, mood, clock.tick)}</span>
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
    font-weight: 500;
  }
</style>
