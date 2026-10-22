<script lang="ts">
  import type { NodeProps } from '@xyflow/svelte';
  import { frameUrl } from '../api';
  import { artifacts } from '../artifacts.svelte';
  import type { ArtifactWindow } from '../board.svelte';
  import { boards } from '../boards.svelte';
  import { ago } from '../format';
  import ArtifactView from '../views/ArtifactView.svelte';
  import WindowFrame from './WindowFrame.svelte';

  // A page the agent made, beside the chat it came from. It follows the
  // newest version unless pinned to one from the version menu.
  let { id, data, selected }: NodeProps<ArtifactWindow> = $props();
  const detail = $derived(artifacts.get(data.artifact));
  const shown = $derived(data.version ?? detail?.version);
  const entry = $derived(detail?.history.find((item) => item.version === shown)?.entry ?? detail?.entry ?? 'index.html');
  let reloads = $state(0);
  let failures = $state<string[]>([]);

  function choose(event: Event) {
    const value = (event.currentTarget as HTMLSelectElement).value;
    boards.board?.pinArtifact(id, value ? Number(value) : null);
  }
</script>

<WindowFrame {id} selected={!!selected} title={detail?.title ?? 'artifact'}>
  {#snippet meta()}
    {#if failures.length}
      <span class="failed" title={failures.join('\n')}>{failures.length === 1 ? 'an error' : `${failures.length} errors`}</span>
    {/if}
    {#if detail && shown}
      <label class="version nodrag" title={data.version === null ? 'following the newest version' : 'pinned to this version'}>
        <span>v{shown}</span>
        {#if detail.versions > 1}<span class="how">{data.version === null ? 'latest' : 'pinned'}</span>{/if}
        <select aria-label="version" value={data.version ?? ''} onchange={choose}>
          <option value="">follow the newest (v{detail.version})</option>
          {#each detail.history as item (item.version)}
            <option value={item.version}>v{item.version} · {ago(new Date(item.created_at).toISOString())}</option>
          {/each}
        </select>
      </label>
      <button class="icon nodrag" aria-label="Reload the page" title="Reload the page" onclick={() => reloads++}>
        <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M13 8a5 5 0 1 1-1.46-3.54M13 3v3h-3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
      </button>
      <a class="icon nodrag" href={frameUrl(detail, shown, entry)} target="_blank" rel="noopener noreferrer" aria-label="Open in a new tab" title="Open in a new tab">
        <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M9 3h4v4M13 3L7.5 8.5M11 9.5V12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h2.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
      </a>
    {/if}
  {/snippet}

  <ArtifactView windowId={id} artifactId={data.artifact} sessionId={data.sessionId} latest={data.latest} version={data.version} {reloads} onfailures={(found) => (failures = found)} />
</WindowFrame>

<style>
  .failed {
    color: var(--danger);
  }
  .version {
    position: relative;
    display: flex;
    align-items: center;
    gap: 5px;
    height: 26px;
    padding: 0 8px;
    font-variant-numeric: tabular-nums;
    border-radius: 8px;
    cursor: pointer;
    transition: background-color 120ms ease, color 120ms ease;
  }
  .version:hover {
    color: var(--text);
    background: var(--hover);
  }
  .version .how {
    color: var(--faint);
  }
  /* The native menu, invisible over the label, so picking a version is the platform's own. */
  .version select {
    position: absolute;
    inset: 0;
    width: 100%;
    opacity: 0;
    cursor: pointer;
  }
  .icon {
    display: grid;
    place-items: center;
    width: 28px;
    height: 28px;
    padding: 0;
    margin: 0 -6px;
    color: var(--muted);
    background: none;
    border: 0;
    border-radius: 8px;
    cursor: pointer;
    transition: background-color 120ms ease, color 120ms ease;
  }
  .icon:hover {
    color: var(--text);
    background: var(--hover);
  }
  .icon:active {
    transform: scale(0.94);
  }
</style>
