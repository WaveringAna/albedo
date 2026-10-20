<script lang="ts">
  import type { SelectedLineRange } from '@pierre/diffs';
  import { namer } from '../burst';
  import { readTurn, turnChanges, type FileChanges } from '../review';

  // The highlighter is large; it loads with the first review.
  const DiffView = import('./DiffView.svelte').then((module) => module.default);

  // A turn's changes, file by file, read from its history and highlighted:
  // the files with their counts, then each file's diffs in order. It is the
  // body of the review window on the canvas and of the review that opens
  // inside a chat on a phone; whoever holds it decides how to scroll to a
  // file and what the margin's comment button does, if anything.
  let {
    sessionId,
    turnId,
    from,
    workspace,
    jump,
    keyOf,
    scroll = (target) => target.scrollIntoView({ behavior: 'smooth', block: 'start' }),
    oncomment,
    count = () => 0,
    onfiles,
  }: {
    sessionId: string;
    turnId: string;
    from: number;
    workspace: string;
    jump?: { path: string; at: number };
    keyOf: (path: string, change: number) => string;
    scroll?: (target: HTMLElement) => void;
    oncomment?: (path: string, change: number, range: SelectedLineRange) => void;
    count?: (path: string) => number;
    onfiles?: (files: FileChanges[]) => void;
  } = $props();

  const name = $derived(namer(workspace));
  let files = $state<FileChanges[] | null>(null);
  let error = $state<string | null>(null);
  let element = $state<HTMLElement>();

  $effect(() => {
    readTurn(sessionId, turnId, from)
      .then(turnChanges)
      .then((found) => {
        files = found;
        onfiles?.(found);
      })
      .catch((failure) => (error = String(failure?.message ?? failure)));
  });

  function show(index: number) {
    const target = element?.querySelector<HTMLElement>(`[data-file="${index}"]`);
    if (target) scroll(target);
  }

  // Asked from a work line in the chat: bring that file into view.
  $effect(() => {
    const path = jump?.path;
    jump?.at;
    const index = files?.findIndex((file) => file.path === path) ?? -1;
    if (index >= 0) requestAnimationFrame(() => show(index));
  });
</script>

<div class="review-view" bind:this={element}>
  {#if error}
    <p class="quiet error">(｡•︿•｡) couldn't read this turn: {error}</p>
  {:else if !files}
    <p class="quiet">(・ω・)ﾉ gathering the changes…</p>
  {:else if !files.length}
    <p class="quiet">(・_・ ) this turn changed no files</p>
  {:else}
    <nav class="index" aria-label="Files">
      {#each files as file, index (file.path)}
        <button onclick={() => show(index)} title={file.path}>
          <span class="path">{name(file.path)}</span>
          {#if count(file.path)}<span class="said" title="notes">{count(file.path)} ✎</span>{/if}
          <span class="counts"><span class="added">+{file.added}</span> <span class="removed">−{file.removed}</span></span>
        </button>
      {/each}
    </nav>
    {#each files as file, index (file.path)}
      <section class="file" data-file={index}>
        <h3 title={file.path}>{name(file.path)}</h3>
        {#each file.changes as change, step (step)}
          {#if change.reason}
            <p class="quiet">no diff to show: {change.reason}</p>
          {:else}
            {#await DiffView then View}
              <View key={keyOf(file.path, step)} path={file.path} change={step} diff={change.diff} oncomment={oncomment && ((range) => oncomment(file.path, step, range))} />
            {/await}
          {/if}
        {/each}
      </section>
    {/each}
  {/if}
</div>

<style>
  .quiet {
    margin: 18px 0;
    color: var(--muted);
    font-size: 12.5px;
    text-align: center;
  }
  .error {
    color: var(--danger);
  }
  .counts {
    font-variant-numeric: tabular-nums;
  }
  .added {
    color: var(--added);
  }
  .removed {
    color: var(--danger);
  }
  .index {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 2px;
    margin-bottom: 18px;
    padding: 6px;
    background: var(--well);
    border-radius: 10px;
  }
  .index button {
    display: flex;
    min-width: 0;
    align-items: baseline;
    gap: 12px;
    padding: 5px 8px;
    color: var(--text);
    font: inherit;
    font-size: 12.5px;
    text-align: left;
    background: none;
    border: 0;
    border-radius: 6px;
    cursor: pointer;
  }
  .index button:hover {
    background: var(--hover);
  }
  .path {
    flex: 0 1 auto;
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .said {
    color: var(--accent);
    font-size: 11.5px;
  }
  .file + .file {
    margin-top: 22px;
  }
  h3 {
    position: sticky;
    top: var(--review-sticky-top, -14px);
    z-index: 1;
    margin: 0 -16px 8px;
    padding: 8px 16px;
    overflow: hidden;
    font-size: 13px;
    font-weight: 600;
    white-space: nowrap;
    text-overflow: ellipsis;
    background: var(--review-ground, var(--surface));
  }
  .file :global(.diff + .diff) {
    margin-top: 10px;
  }
</style>
