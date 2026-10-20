<script lang="ts">
  import type { SelectedLineRange } from '@pierre/diffs';
  import type { NodeProps } from '@xyflow/svelte';
  import { useViewport } from '@xyflow/svelte';
  import { diffKey, diffs, quoteLines } from '../anchors';
  import { sendMessage, uuidv7 } from '../api';
  import { NOTE, type ReviewWindow } from '../board.svelte';
  import { boards } from '../boards.svelte';
  import { namer } from '../burst';
  import { sendNotes } from '../notes';
  import { readTurn, turnChanges, type FileChanges } from '../review';
  import { sessions } from '../sessions.svelte';
  import WindowFrame from './WindowFrame.svelte';

  // The highlighter is large; it loads with the first review.
  const DiffView = import('../views/DiffView.svelte').then((module) => module.default);

  // A turn's changes, file by file, read from its history and highlighted.
  // The margin beside any line (drag for several) leaves a note out on the
  // canvas beside the window, tied to those lines; "send review" sends every
  // note tied into this review as one message.
  let { id, data, selected }: NodeProps<ReviewWindow> = $props();
  const session = $derived(sessions.byId.get(data.sessionId));
  const name = $derived(namer(session?.workspace ?? ''));
  const viewport = useViewport();

  let files = $state<FileChanges[] | null>(null);
  let error = $state<string | null>(null);
  let body = $state<HTMLElement>();
  let node = $state<HTMLElement>();
  let summary = $state('');
  let sending = $state(false);
  let problem = $state('');
  // Where the last press in the window was, so a note lands level with the line it came from.
  let pointerY = 0;

  const notes = $derived(boards.board?.notesOn(id) ?? []);
  const waiting = $derived(notes.filter((note) => !note.data.sent && note.data.text.trim()));

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

  /** Leaves a note beside the window, level with the lines it is about. */
  function comment(path: string, change: number, range: SelectedLineRange) {
    const board = boards.board;
    const known = diffs.get(diffKey(id, path, change));
    if (!board?.flow || !node || !known) return;
    const side = range.endSide ?? range.side ?? 'additions';
    const [start, end] = range.start <= range.end ? [range.start, range.end] : [range.end, range.start];
    const spot = board.besideWindow(id, pointerY - 16);
    if (!spot) return;
    // Step down past notes already there, so they never stack.
    for (const other of board.notesOn(id)) if (Math.abs(other.position.x - spot.x) < NOTE.width && Math.abs(other.position.y - spot.y) < 60) spot.y = other.position.y + 72;
    board.addNote(spot, { kind: 'lines', window: id, path, change, side, start, end, quote: quoteLines(known.diff, side, start, end) });
  }

  async function send() {
    const board = boards.board;
    if (!board || (!waiting.length && !summary.trim())) return;
    sending = true;
    problem = '';
    try {
      if (waiting.length) await sendNotes(board, waiting, `Review of your changes:${summary.trim() ? `\n\n${summary.trim()}` : ''}`);
      else await sendMessage(data.sessionId, uuidv7(), `Review of your changes:\n\n${summary.trim()}`);
      summary = '';
    } catch (failure) {
      problem = String((failure as Error).message ?? failure);
    } finally {
      sending = false;
    }
  }

  function count(path: string) {
    return notes.filter((note) => note.data.target?.kind === 'lines' && note.data.target.path === path && !note.data.sent).length;
  }
</script>

<div class="review-node" bind:this={node} onpointerdowncapture={(event) => (pointerY = event.clientY)}>
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
                <View key={diffKey(id, file.path, step)} path={file.path} change={step} diff={change.diff} oncomment={(range) => comment(file.path, step, range)} />
              {/await}
            {/if}
          {/each}
        </section>
      {/each}
    {/if}
  </div>
  {#if files?.length}
    <footer class="send">
      <textarea bind:value={summary} rows="1" placeholder={waiting.length ? 'overall, optional' : 'overall, or + beside a line to leave a note'}></textarea>
      {#if problem}<span class="problem" title={problem}>not sent</span>{/if}
      <button disabled={sending || (!waiting.length && !summary.trim())} onclick={send}>
        send review{waiting.length ? ` · ${waiting.length}` : ''}
      </button>
    </footer>
  {/if}
</WindowFrame>


</div>

<style>
  .review-node {
    position: relative;
    display: flex;
    width: 100%;
    height: 100%;
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
