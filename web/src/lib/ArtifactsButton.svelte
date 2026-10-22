<script lang="ts">
  import { listArtifacts, type Artifact } from './api';
  import { ago } from './format';
  import MenuButton from './MenuButton.svelte';

  // The artifacts a session made: a page icon, with how many, that lists
  // them newest change first and opens one. Read again when the session's
  // work stops and when the list opens. Nothing shows until there is one.
  let { sessionId, busy = false, up = false, onopen }: { sessionId: string; busy?: boolean; up?: boolean; onopen: (artifact: Artifact) => void } = $props();
  let made = $state<Artifact[]>([]);
  let listed = $state(false);

  $effect(() => {
    void busy;
    void listed;
    const reading = new AbortController();
    listArtifacts({ session: sessionId, signal: reading.signal }).then(
      (found) => (made = found),
      () => {},
    );
    return () => reading.abort();
  });
</script>

{#if made.length}
  <MenuButton label="artifacts this session made" count={made.length} {up} bind:open={listed}>
    {#snippet icon()}
      <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true"><rect x="2" y="3" width="12" height="10" rx="2" fill="none" stroke="currentColor" stroke-width="1.4" /><path d="M2 6h12" stroke="currentColor" stroke-width="1.4" /></svg>
    {/snippet}
    {#each made as artifact (artifact.id)}
      <li>
        <button onclick={() => ((listed = false), onopen(artifact))}>
          <span class="title" title={artifact.title}>{artifact.title}</span>
          <span class="when">{artifact.versions > 1 ? `v${artifact.version}` : ''}</span>
          <span class="when">{ago(new Date(artifact.updated_at).toISOString())}</span>
        </button>
      </li>
    {/each}
  </MenuButton>
{/if}

<style>
  .title {
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
</style>
