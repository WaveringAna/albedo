<script lang="ts">
  import type { NodeProps } from '@xyflow/svelte';
  import type { ReviewWindow } from '../board.svelte';
  import { namer } from '../burst';
  import { readTurn, turnChanges, type FileChanges } from '../review';
  import { sessions } from '../sessions.svelte';
  import type { DiffLineAnnotation } from '@pierre/diffs';
  import { useViewport } from '@xyflow/svelte';
  import { Review, type Note } from '../review.svelte';
  import CommentNote from '../views/CommentNote.svelte';
  import WindowFrame from './WindowFrame.svelte';

  // The highlighter is large; it loads with the first review.
  const DiffView = import('../views/DiffView.svelte').then((module) => module.default);

  // A turn's changes, file by file, read from its history and highlighted.
  // The margin beside any line starts a comment on it (drag to cover
  // several); "send review" posts every comment as one message. Comments do
  // not break the file open: each sits out on the canvas to the right of the
  // window, level with its lines, tied to them by a short line.
  let { id, data, selected }: NodeProps<ReviewWindow> = $props();
  const session = $derived(sessions.byId.get(data.sessionId));
  const name = $derived(namer(session?.workspace ?? ''));

  let files = $state<FileChanges[] | null>(null);
  let error = $state<string | null>(null);
  let body = $state<HTMLElement>();
  // svelte-ignore state_referenced_locally
  const review = new Review(data.sessionId, () => files ?? []);

  $effect(() => {
    const { sessionId, turnId, from } = data;
    readTurn(sessionId, turnId, from)
      .then(turnChanges)
      .then((found) => (files = found))
      .catch((failure) => (error = String(failure?.message ?? failure)));
  });

  const added = $derived(files?.reduce((sum, file) => sum + file.added, 0) ?? 0);
  const removed = $derived(files?.reduce((sum, file) => sum + file.removed, 0) ?? 0);

  // Scrolls only the body: scrollIntoView would also scroll the canvas
  // behind the window, which is not meant to scroll at all.
  function jump(index: number) {
    const target = body?.querySelector<HTMLElement>(`[data-file="${index}"]`);
    if (!body || !target) return;
    const zoom = viewport.current.zoom || 1;
    const top = body.scrollTop + (target.getBoundingClientRect().top - body.getBoundingClientRect().top) / zoom - 8;
    body.scrollTo({ top, behavior: 'smooth' });
  }

  // Asked from a work line in the chat: bring that file into view.
  $effect(() => {
    const path = data.jump?.path;
    data.jump?.at;
    const index = files?.findIndex((file) => file.path === path) ?? -1;
    if (index >= 0) requestAnimationFrame(() => jump(index));
  });

  // Where each comment's lines are, in the window's own pixels, measured
  // from the anchors the diffs leave; read again as the body scrolls or the
  // diffs redraw.
  const viewport = useViewport();
  let node = $state<HTMLElement>();
  let places = $state<Record<string, { y: number; shown: boolean }>>({});
  let frame = 0;

  function anchor(annotation: DiffLineAnnotation<Note>) {
    const element = document.createElement('div');
    element.dataset.commentAnchor = annotation.metadata.id;
    return element;
  }

  function measure() {
    cancelAnimationFrame(frame);
    frame = requestAnimationFrame(() => {
      if (!node || !body) return;
      const zoom = viewport.current.zoom || 1;
      const origin = node.getBoundingClientRect();
      const visible = body.getBoundingClientRect();
      const next: typeof places = {};
      for (const element of node.querySelectorAll<HTMLElement>('[data-comment-anchor]')) {
        const at = element.getBoundingClientRect().top;
        next[element.dataset.commentAnchor!] = { y: (at - origin.top) / zoom, shown: at >= visible.top - 4 && at <= visible.bottom + 4 };
      }
      places = next;
    });
  }

  // Cards keep their order down the margin and never overlap.
  const CARD_GAP = 8;
  let heights = $state<Record<string, number>>({});
  const cards = $derived.by(() => {
    let floor = -Infinity;
    return review.comments
      .filter((comment) => places[comment.id]?.shown)
      .sort((a, b) => places[a.id].y - places[b.id].y)
      .map((comment) => {
        const line = places[comment.id].y;
        const top = Math.max(line - 14, floor);
        floor = top + (heights[comment.id] ?? 60) + CARD_GAP;
        return { comment, line, top };
      });
  });

  $effect(() => {
    review.comments;
    measure();
  });

  function count(path: string) {
    return review.added.filter((comment) => comment.path === path).length;
  }
</script>

<div class="review-node" bind:this={node}>
<WindowFrame {id} selected={!!selected} title="review · {session?.name || 'untitled session'}">
  {#snippet meta()}
    {#if files}
      <span>{files.length} {files.length === 1 ? 'file' : 'files'}</span>
      <span class="counts"><span class="added">+{added}</span> <span class="removed">−{removed}</span></span>
    {/if}
  {/snippet}

  <div class="review nowheel" bind:this={body} onscroll={measure}>
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
            {#if count(file.path)}<span class="said" title="comments">{count(file.path)} ✎</span>{/if}
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
                <View path={file.path} diff={change.diff} notes={review.notesFor(file.path, step)} {anchor} oncomment={(range) => review.start(file.path, step, range)} onrender={measure} />
              {/await}
            {/if}
          {/each}
        </section>
      {/each}
    {/if}
  </div>
  {#if files?.length}
    <footer class="send">
      <textarea bind:value={review.summary} rows="1" placeholder={review.sent ? 'sent ✓ · anything more?' : 'overall, optional'}></textarea>
      {#if review.error}<span class="problem" title={review.error}>not sent</span>{/if}
      <button disabled={review.sending || (!review.added.length && !review.summary.trim())} onclick={() => review.send()}>
        send review{review.added.length ? ` · ${review.added.length}` : ''}
      </button>
    </footer>
  {/if}
</WindowFrame>

{#each cards as card (card.comment.id)}
  <svg class="tie" style:top="{card.line}px" style:height="{Math.max(2, card.top + 14 - card.line + 2)}px" aria-hidden="true">
    <path d="M0 1 H18 V{Math.max(1, card.top + 14 - card.line + 1)} H36" fill="none" />
  </svg>
  <div class="card nodrag nowheel" style:top="{card.top}px" bind:clientHeight={heights[card.comment.id]}>
    <CommentNote comment={card.comment} {review} />
  </div>
{/each}
</div>

<style>
  .review-node {
    position: relative;
    display: flex;
    width: 100%;
    height: 100%;
  }
  .tie {
    position: absolute;
    left: calc(100% - 4px);
    width: 40px;
    overflow: visible;
    pointer-events: none;
  }
  .tie path {
    stroke: color-mix(in oklab, var(--accent) 55%, transparent);
    stroke-width: 1.5;
    stroke-dasharray: 3 4;
  }
  .card {
    position: absolute;
    left: calc(100% + 36px);
    z-index: 2;
  }
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
  .file :global(.diff + .diff) {
    margin-top: 10px;
  }
  .said {
    color: var(--accent);
    font-size: 11.5px;
  }
  .send {
    display: flex;
    align-items: flex-end;
    gap: 8px;
    padding: 10px 12px;
    background: var(--title-bar);
  }
  .send textarea {
    flex: 1;
    min-height: 30px;
    max-height: 140px;
    padding: 6px 10px;
    color: var(--text);
    font: inherit;
    font-size: 13px;
    background: var(--field);
    border: 0;
    border-radius: 8px;
    outline: 0;
    resize: none;
    field-sizing: content;
  }
  .send button {
    height: 30px;
    padding: 0 12px;
    color: var(--surface);
    font: inherit;
    font-size: 12.5px;
    font-weight: 560;
    white-space: nowrap;
    background: var(--accent);
    border: 0;
    border-radius: 8px;
    cursor: pointer;
  }
  .send button:disabled {
    opacity: 0.35;
    cursor: default;
  }
  .problem {
    align-self: center;
    color: var(--danger);
    font-size: 11.5px;
  }
</style>
