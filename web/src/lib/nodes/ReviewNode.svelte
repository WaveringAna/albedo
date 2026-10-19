<script lang="ts">
  import type { NodeProps } from '@xyflow/svelte';
  import type { ReviewWindow } from '../board.svelte';
  import { namer } from '../burst';
  import { parseDiff, readTurn, turnChanges, type FileChanges } from '../review';
  import { sessions } from '../sessions.svelte';
  import WindowFrame from './WindowFrame.svelte';

  // A turn's changes, file by file, read from its history. Read-only for
  // now; marks and albedo's notes on each hunk come next.
  let { id, data, selected }: NodeProps<ReviewWindow> = $props();
  const session = $derived(sessions.byId.get(data.sessionId));
  const name = $derived(namer(session?.workspace ?? ''));

  let files = $state<FileChanges[] | null>(null);
  let error = $state<string | null>(null);
  let body = $state<HTMLElement>();

  $effect(() => {
    const { sessionId, turnId, from } = data;
    readTurn(sessionId, turnId, from)
      .then(turnChanges)
      .then((found) => (files = found))
      .catch((failure) => (error = String(failure?.message ?? failure)));
  });

  const added = $derived(files?.reduce((sum, file) => sum + file.added, 0) ?? 0);
  const removed = $derived(files?.reduce((sum, file) => sum + file.removed, 0) ?? 0);

  function jump(index: number) {
    body?.querySelector(`[data-file="${index}"]`)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
</script>

<WindowFrame {id} selected={!!selected} title="review · {session?.name || 'untitled session'}">
  {#snippet meta()}
    {#if files}
      <span>{files.length} {files.length === 1 ? 'file' : 'files'}</span>
      <span class="counts"><span class="added">+{added}</span> <span class="removed">−{removed}</span></span>
    {/if}
  {/snippet}

  <div class="review nowheel" bind:this={body}>
    {#if error}
      <p class="quiet error">(｡•︿•｡) couldn't read this turn: {error}</p>
    {:else if !files}
      <p class="quiet">(・ω・)ﾉ gathering the changes…</p>
    {:else if !files.length}
      <p class="quiet">(・_・ ) this turn changed no files</p>
    {:else}
      <nav class="index" aria-label="Files">
        {#each files as file, index (file.path)}
          <button onclick={() => jump(index)} title={file.path}>
            <span class="path">{name(file.path)}</span>
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
              <div class="diff">
                {#each parseDiff(change.diff) as line, row (row)}
                  {#if line.kind === 'hunk'}
                    <div class="hunk">{line.text || '···'}</div>
                  {:else}
                    <div class="line {line.kind}">
                      <span class="number">{line.old ?? ''}</span>
                      <span class="number">{line.new ?? ''}</span>
                      <span class="sign">{line.kind === 'add' ? '+' : line.kind === 'remove' ? '−' : ''}</span>
                      <span class="text">{line.text}</span>
                    </div>
                  {/if}
                {/each}
              </div>
            {/if}
          {/each}
        </section>
      {/each}
    {/if}
  </div>
</WindowFrame>

<style>
  .review {
    flex: 1;
    min-height: 0;
    padding: 14px 16px 24px;
    overflow-y: auto;
    overscroll-behavior: contain;
    scrollbar-width: thin;
  }
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
    flex: 1;
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .file + .file {
    margin-top: 22px;
  }
  h3 {
    position: sticky;
    top: -14px;
    z-index: 1;
    margin: 0 -16px 8px;
    padding: 8px 16px;
    overflow: hidden;
    font-size: 13px;
    font-weight: 600;
    white-space: nowrap;
    text-overflow: ellipsis;
    background: var(--surface);
  }
  .diff {
    overflow-x: auto;
    font-family: var(--mono);
    font-size: 12px;
    line-height: 1.55;
    background: var(--well);
    border-radius: 10px;
    scrollbar-width: thin;
  }
  .diff + .diff {
    margin-top: 10px;
  }
  .hunk {
    padding: 4px 12px;
    color: var(--muted);
    font-size: 11.5px;
    background: color-mix(in oklab, var(--accent) 7%, transparent);
  }
  .line {
    display: grid;
    grid-template-columns: 3.2em 3.2em 1.4em max-content;
    min-width: 100%;
    width: max-content;
  }
  .number {
    padding-right: 8px;
    color: var(--faint);
    text-align: right;
    user-select: none;
  }
  .sign {
    color: var(--muted);
    text-align: center;
    user-select: none;
  }
  .text {
    padding-right: 16px;
    white-space: pre;
  }
  .add {
    background: color-mix(in oklab, var(--added) 10%, transparent);
  }
  .add .sign {
    color: var(--added);
  }
  .remove {
    background: color-mix(in oklab, var(--danger) 10%, transparent);
  }
  .remove .sign {
    color: var(--danger);
  }
</style>
