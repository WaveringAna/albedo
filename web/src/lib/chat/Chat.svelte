<script lang="ts">
  import { onMount, tick, type Snippet } from 'svelte';
  import { busy } from '../live.svelte';
  import { boards } from '../boards.svelte';
  import { copyText, interruptSession, uuidv7, type Session } from '../api';
  import { sessions } from '../sessions.svelte';
  import { sendNotes } from '../notes';
  import type { Attached } from './attachments';
  import LiveFace from '../LiveFace.svelte';
  import { face, formatElapsed } from '../moods';
  import { Transcript } from '../transcript.svelte';
  import Composer from './Composer.svelte';
  import Markdown from './Markdown.svelte';
  import Receipt from './Receipt.svelte';
  import WorkSteps from './WorkSteps.svelte';
  import ReviewView from '../views/ReviewView.svelte';
  import ModelPicker from './ModelPicker.svelte';
  import { catalogue, invoke, type Command } from '../commands';

  // On the canvas a chat is a window, whose reviews and notes open beside
  // it. `inline` is the phone's single chat: a review opens inside the chat,
  // under the line that asked for it, and there are no notes.
  let {
    sessionId,
    session,
    windowId,
    inline = false,
    handle,
  }: { sessionId: string; session: Session | undefined; windowId: string; inline?: boolean; handle?: Snippet } = $props();

  let shown = $state<{ at: string; turnId: string; from: number; jump?: { path: string; at: number } } | null>(null);

  /** Opens a turn's review: beside the window, or under the line it was asked from. */
  function review(at: string, turnId: string, from: number, path?: string) {
    if (!inline) return boards.board?.openReview(sessionId, turnId, from, windowId, path);
    const jump = path ? { path, at: Date.now() } : undefined;
    shown = shown?.at === at && shown.turnId === turnId && !path ? null : { at, turnId, from, jump };
  }

  // svelte-ignore state_referenced_locally
  const transcript = new Transcript(sessionId);
  // The stream's phase is fresher than the session list's; the list answers until the stream does.
  const view = $derived(session && transcript.phase ? { ...session, status: { ...session.status!, phase: transcript.phase } } : session);
  const running = $derived(busy(view));
  $effect(() => {
    transcript.running = running;
  });
  let copied = $state<string | null>(null);

  async function copy(key: string, text: string) {
    await copyText(text);
    copied = key;
    setTimeout(() => copied === key && (copied = null), 1400);
  }
  const last = $derived(transcript.groups.at(-1));
  const activity = $derived(session?.activity?.lines.findLast((line) => line.text.trim())?.text.trim() ?? '');

  let scroller = $state<HTMLElement>();
  let top = $state<HTMLElement>();
  let pinned = $state(true);
  let dockHeight = $state(0);
  // The end of the chat as it was when the reader scrolled up from it, so a
  // new message or more of a reply below can be told from older ones loading
  // above.
  const end = $derived(`${transcript.groups.at(-1)?.key ?? ''}:${transcript.live.reduce((length, item) => length + item.text.length, 0)}`);
  let leftAt = $state<string | null>(null);
  const unseen = $derived(!pinned && leftAt !== null && end !== leftAt);
  let settled = $state(false);
  let older = false;

  onMount(() => {
    transcript
      .load()
      .then(toBottom)
      .finally(() => (settled = true));
    transcript.attach();
    return () => transcript.detach();
  });

  // The stream says when history grows. Polling is the fallback while it is
  // down, quick while the session works.
  $effect(() => {
    const every = transcript.streaming ? 20_000 : running || transcript.pending.length ? 1200 : 5000;
    let timer: ReturnType<typeof setTimeout>;
    const tickOnce = async () => {
      if (!document.hidden && !transcript.loading) await transcript.poll().catch(() => {});
      timer = setTimeout(tickOnce, every);
    };
    timer = setTimeout(tickOnce, every);
    return () => clearTimeout(timer);
  });

  // Earlier pages load one at a time when the reader nears the top, keeping
  // their place. Watching starts once the first page sits at the bottom.
  $effect(() => {
    if (!top || !scroller || !settled) return;
    const observer = new IntersectionObserver(
      async ([entry]) => {
        if (!entry.isIntersecting || !transcript.more || older || !scroller) return;
        older = true;
        const before = scroller.scrollHeight;
        try {
          await transcript.loadOlder();
          await tick();
          scroller.scrollTop += scroller.scrollHeight - before;
        } finally {
          older = false;
        }
      },
      { root: scroller, rootMargin: '200px 0px 0px 0px' },
    );
    observer.observe(top);
    return () => observer.disconnect();
  });

  // Stay at the bottom as messages arrive, unless the reader scrolled up.
  $effect(() => {
    transcript.groups;
    activity;
    transcript.live;
    if (pinned) toBottom();
  });

  async function toBottom() {
    await tick();
    if (scroller) scroller.scrollTop = scroller.scrollHeight;
  }

  // On a phone the composer floats over the thread, which scrolls on under it;
  // a draft growing taller must not bury the end of a chat that was there.
  $effect(() => {
    if (!inline) return;
    dockHeight;
    if (pinned) toBottom();
  });

  function scrolled() {
    if (!scroller) return;
    const was = pinned;
    pinned = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 40;
    if (was && !pinned) leftAt = end;
    else if (pinned) leftAt = null;
  }

  // Back to the end in a quarter second however far it is (the browser's own
  // smooth scroll crawls over a long chat); a wheel or touch takes over.
  const LATEST_MS = 250;
  function latest() {
    const element = scroller;
    if (!element) return;
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    const from = element.scrollTop;
    const start = performance.now();
    let frame = 0;
    const stop = () => {
      cancelAnimationFrame(frame);
      element.removeEventListener('wheel', stop);
      element.removeEventListener('touchstart', stop);
    };
    element.addEventListener('wheel', stop, { passive: true });
    element.addEventListener('touchstart', stop, { passive: true });
    const step = (now: number) => {
      const t = Math.min(1, (now - start) / LATEST_MS);
      // Measured each frame: the end can grow while it travels.
      const to = element.scrollHeight - element.clientHeight;
      element.scrollTop = from + (to - from) * (1 - (1 - t) ** 3);
      if (t < 1) frame = requestAnimationFrame(step);
      else stop();
    };
    frame = requestAnimationFrame(step);
  }

  // Notes tied to this chat or anything in it go as one message.
  const tied = $derived((boards.board?.notesOn(windowId) ?? []).filter((note) => !note.data.sent && note.data.text.trim()));
  let sendingNotes = $state(false);
  async function sendTied() {
    if (!boards.board) return;
    sendingNotes = true;
    try {
      await sendNotes(boards.board, tied);
    } finally {
      sendingNotes = false;
    }
  }

  /** Moves the draft into a note beside the window, for writing at length. */
  function popout(text: string) {
    const board = boards.board;
    const frame = scroller?.closest('.svelte-flow__node')?.getBoundingClientRect();
    const spot = frame && board?.besideWindow(windowId, frame.bottom - 240);
    if (board && spot) board.addNote(spot, { kind: 'window', window: windowId }, text);
  }

  function send(text: string, images: Attached[]) {
    pinned = true;
    transcript.send(text, images);
  }

  // Slash commands: skills and command inputs join the transcript like a
  // message; reads and changes answer here, above the composer, until dismissed.
  let commands = $state<Command[]>([]);
  let answer = $state<{ name: string; text: string; failed: boolean } | null>(null);
  $effect(() => {
    catalogue(sessionId).then((found) => (commands = found));
  });

  async function command(chosen: Command, rest: string) {
    answer = null;
    try {
      const outcome = await invoke(sessionId, chosen, rest, uuidv7());
      if (outcome) answer = { name: chosen.slash_name, text: chosen.delivery === 'mutation' ? 'done' : describe(outcome.result), failed: false };
      else pinned = true;
      if (chosen.delivery === 'mutation') sessions.refresh();
    } catch (error) {
      answer = { name: chosen.slash_name, text: String((error as Error).message ?? error), failed: true };
    }
  }

  /** A command's answer as text: its message when it has one, else the JSON. */
  function describe(result: unknown): string {
    if (typeof result === 'string') return result;
    const record = result as Record<string, unknown> | null;
    for (const key of ['text', 'message', 'summary']) if (typeof record?.[key] === 'string') return record[key] as string;
    return JSON.stringify(result, null, 2);
  }
</script>

{#snippet modelChip()}<ModelPicker session={session!} />{/snippet}

<div class="chat" class:inline style:--dock={inline ? `${dockHeight}px` : undefined}>
  <div class="scroller nowheel" bind:this={scroller} onscroll={scrolled}>
    {#if !settled && !transcript.error}
      <!-- Shaped like the end of a typical chat, as measured at phone width:
           a work line, your message, more work, then the reply's last lines
           and its sign-off, sitting at the bottom where the chat will open. -->
      <div class="skeleton" aria-label="loading the chat" role="status">
        <span class="bar work"></span>
        <span class="bubble-shape"></span>
        <span class="bar work"></span>
        {#each [92, 100, 84, 96, 70, 88, 100, 60] as width, index (index)}<span class="bar line" style:width="{width}%"></span>{/each}
        <span class="bar end"></span>
      </div>
    {/if}
    <div class="thread" class:waiting={!settled}>
      <div bind:this={top}></div>
      {#if transcript.loading}
        <span></span>
      {:else if transcript.error}
        <p class="quiet error">(｡•︿•｡) couldn't read the transcript: {transcript.error}</p>
      {:else if transcript.groups.length === 0}
        <p class="quiet">(˶ᵔ ᵕ ᵔ˶) nothing here yet. say hi below</p>
      {:else if transcript.more}
        <p class="quiet">earlier messages load as you scroll up</p>
      {/if}

      {#each transcript.groups as group (group.key)}
        {#if group.kind === 'user'}
          {@const unseen = group.state === 'sending' || group.state === 'sent'}
          <div class="user" class:failed={group.state === 'failed'} data-entry={group.key}>
            {#if group.from || group.gap}
              <span class="plate"><span class:you={!group.from}>{group.from ?? 'you'}</span>{#if group.gap}<span class="meta">{' · '}{group.gap}</span>{/if}</span>
            {/if}
            {#if group.images.length}
              <div class="pictures" class:unseen>
                {#each group.images as picture, index (index)}
                  <a href={picture.src} target="_blank" rel="noopener noreferrer" title="Image #{index + 1}">
                    <img src={picture.src} alt="Image #{index + 1}" width={picture.width} height={picture.height} loading="lazy" />
                  </a>
                {/each}
              </div>
            {/if}
            {#if group.text.trim()}
              <div class="bubble" class:unseen>{group.text}</div>
            {/if}
            {#if transcript.receipt === group.key && group.state !== 'failed'}
              <Receipt state={group.state} />
            {/if}
            {#if group.state === 'failed'}
              <span class="problem">
                not sent: {group.error}
                <button onclick={() => transcript.retry(group.key.slice('pending:'.length))}>retry</button>
                <button onclick={() => transcript.discard(group.key.slice('pending:'.length))}>discard</button>
              </span>
            {/if}
          </div>
        {:else if group.kind === 'assistant'}
          <div class="assistant" data-entry={group.key}>
            {#if group.plate}<span class="plate agent">albedo</span>{/if}
            <Markdown text={group.text} />
          </div>
        {:else if group.kind === 'work'}
          <WorkSteps steps={group.steps} live={running && group === last} {transcript} session={view} onreview={(turnId, from, path) => review(group.key, turnId, from, path)} />
        {:else if group.kind === 'end'}
          <p class="end">
            <span class="face kaomoji" title={group.mood}>{face(group.mood, group.seed)}</span>
            <span class="meta">{[group.elapsedMs >= 1000 ? formatElapsed(group.elapsedMs) : '', group.tools ? `${group.tools} ${group.tools === 1 ? 'tool' : 'tools'}` : ''].filter(Boolean).join(' · ')}</span>
            {#if group.changed.files && group.turnId}
              <button class="review" title="review this turn's changes" aria-expanded={inline ? shown?.at === group.key : undefined} onclick={() => review(group.key, group.turnId!, group.from)}>
                review {group.changed.files} {group.changed.files === 1 ? 'file' : 'files'}
                {#if group.changed.added || group.changed.removed}<span class="added">+{group.changed.added}</span> <span class="removed">−{group.changed.removed}</span>{/if}
              </button>
            {/if}
            {#if group.text}
              <button class="copy" onclick={() => copy(group.key, group.text)}>{copied === group.key ? 'copied' : 'copy'}</button>
            {/if}
          </p>
        {:else if group.kind === 'note'}
          <p class="note">{group.text}</p>
        {:else if group.kind === 'compaction'}
          <p class="note">{'(>_<)'} earlier context was compacted here</p>
        {/if}
        {#if shown?.at === group.key}
          <section class="inline-review" aria-label="changes">
            <header>
              <span>changes</span>
              <button onclick={() => (shown = null)} aria-label="close the changes">close</button>
            </header>
            <ReviewView sessionId={sessionId} turnId={shown.turnId} from={shown.from} workspace={session?.workspace ?? ''} jump={shown.jump} keyOf={(path, change) => `${windowId}#${path}#${change}`} />
          </section>
        {/if}
      {/each}

      {#if running}
        <p class="live"><LiveFace session={view} label />{#if !transcript.streaming && activity}<span class="activity">{activity}</span>{/if}</p>
      {/if}
    </div>
  </div>

  <div class="dock" bind:offsetHeight={dockHeight}>
    {#if settled && !pinned}
      <button class="latest" onclick={latest}>
        <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path d="M8 3v10M3.5 8.5 8 13l4.5-4.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
        {unseen ? 'see new messages' : 'back to latest'}
      </button>
    {/if}
    {@render handle?.()}
    {#if tied.length}
      <button class="notes" disabled={sendingNotes} onclick={sendTied}>send {tied.length} {tied.length === 1 ? 'note' : 'notes'} tied to this chat</button>
    {/if}
    {#if answer}
      <section class="answer" class:failed={answer.failed} aria-live="polite">
        <header><span>{answer.name}</span><button aria-label="dismiss" onclick={() => (answer = null)}>×</button></header>
        <pre>{answer.text}</pre>
      </section>
    {/if}
    <Composer onsend={send} busy={running} {commands} oncommand={command} compact={inline} extra={session && !inline ? modelChip : undefined} onpopout={inline ? undefined : popout} onstop={() => interruptSession(sessionId)} />
  </div>
</div>

<style>
  /* The chat reads a size up from the rest of the canvas; everything in it,
     text and the spacing around it, scales together. */
  .chat {
    display: flex;
    flex: 1;
    flex-direction: column;
    min-height: 0;
    zoom: 1.15;
  }
  /* On a phone the chat is the whole screen: no scaling, the reading size
     set outright, and the room at the sides given back to the text. */
  .chat.inline {
    position: relative;
    zoom: 1;
  }
  /* The thread ends clear of the floating composer and the handle above it. */
  .inline .thread {
    gap: 12px;
    padding: 12px 16px calc(var(--dock, 0px) + 32px);
    font-size: 16px;
    line-height: 1.55;
  }
  .inline .dock {
    position: absolute;
    right: 0;
    bottom: 0;
    left: 0;
    padding: 0 10px 8px;
  }
  /* Floats over the end of the thread while it is scrolled up, in the
     composer's tone; on a phone, above the drawer's handle. */
  .latest {
    position: absolute;
    bottom: calc(100% + 8px);
    left: 50%;
    z-index: 2;
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 13px 6px 10px;
    color: var(--text);
    font: inherit;
    font-size: 12.5px;
    white-space: nowrap;
    background: var(--field);
    border: 0;
    border-radius: 999px;
    box-shadow: 0 1px 2px rgb(0 0 0 / 0.1);
    cursor: pointer;
    transform: translateX(-50%);
  }
  .latest:hover {
    background: color-mix(in oklab, var(--field), var(--text) 6%);
  }
  .latest svg {
    color: var(--accent);
  }
  .inline .latest {
    bottom: calc(100% + 34px);
  }
  /* Until the first page is in and scrolled to its end, the thread stays
     unseen and the skeleton holds its place, so it never shows its top and
     then jumps. */
  .thread.waiting {
    visibility: hidden;
  }
  .skeleton {
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    justify-content: flex-end;
    gap: 12px;
    max-width: 720px;
    margin: 0 auto;
    padding: 18px 20px 24px;
    overflow: hidden;
    pointer-events: none;
  }
  .inline .skeleton {
    padding: 12px 16px calc(var(--dock, 0px) + 32px);
  }
  .skeleton > * {
    flex: none;
    border-radius: 8px;
    background: var(--well);
    animation: pulse 1.6s ease-in-out infinite;
  }
  .skeleton .work {
    width: 58%;
    height: 14px;
    margin: 4px 0;
  }
  .skeleton .bubble-shape {
    align-self: flex-end;
    width: 64%;
    height: 72px;
    border-radius: 16px 16px 4px 16px;
    background: var(--bubble);
  }
  .skeleton .line {
    height: 14px;
    margin: 0;
  }
  .skeleton .line + .line {
    margin-top: -2px;
  }
  .skeleton .end {
    width: 30%;
    height: 12px;
  }
  @keyframes pulse {
    50% {
      opacity: 0.55;
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .skeleton > * {
      animation: none;
    }
  }
  .scroller {
    position: relative;
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    overscroll-behavior: contain;
    scrollbar-width: thin;
  }
  .thread {
    display: flex;
    flex-direction: column;
    gap: 14px;
    max-width: 720px;
    margin: 0 auto;
    padding: 18px 20px 24px;
    font-size: 14px;
    line-height: 1.6;
  }
  .quiet {
    margin: 0;
    color: var(--muted);
    font-size: 12px;
    text-align: center;
  }
  .error {
    color: var(--danger);
  }
  .user {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 3px;
    margin-top: 6px;
  }
  .plate {
    color: var(--muted);
    font-size: 12px;
    font-weight: 560;
  }
  .plate .meta {
    font-weight: 400;
  }
  .you {
    color: var(--you);
  }
  .agent {
    display: block;
    margin-bottom: 2px;
    color: var(--agent);
  }
  .end {
    display: flex;
    align-items: baseline;
    gap: 8px;
    margin: -4px 0 4px;
    color: var(--muted);
    font-size: 12px;
  }
  .end .face {
    color: var(--agent);
    font-size: 13px;
  }
  .review {
    padding: 1px 8px;
    color: var(--text);
    font: inherit;
    background: var(--well);
    border: 0;
    border-radius: 6px;
    cursor: pointer;
    transition: background-color 120ms ease;
  }
  .review:hover {
    background: var(--selected);
  }
  .review .added {
    color: var(--added);
  }
  .review .removed {
    color: var(--danger);
  }
  .copy {
    padding: 0 4px;
    color: var(--muted);
    font: inherit;
    background: none;
    border: 0;
    border-radius: 4px;
    cursor: pointer;
    opacity: 0;
    transition: opacity 120ms ease, color 120ms ease;
  }
  .end:hover .copy,
  .copy:focus-visible {
    opacity: 1;
  }
  .copy:hover {
    color: var(--text);
  }
  .inline-review {
    margin: 4px 0 14px;
    padding: 10px 12px 14px;
    background: var(--well);
    border-radius: 12px;
    --review-ground: var(--well);
    --review-sticky-top: -1px;
  }
  .inline-review header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 8px;
    color: var(--muted);
    font-size: 12px;
  }
  .inline-review header button {
    padding: 2px 8px;
    color: var(--muted);
    font: inherit;
    background: none;
    border: 0;
    border-radius: 6px;
    cursor: pointer;
  }
  .inline-review header button:hover {
    color: var(--text);
    background: var(--hover);
  }
  .notes {
    align-self: flex-start;
    margin: 0 0 8px 6px;
    padding: 3px 10px;
    color: var(--accent);
    font: inherit;
    font-size: 12px;
    background: color-mix(in oklab, var(--accent) 10%, transparent);
    border: 0;
    border-radius: 999px;
    cursor: pointer;
  }
  .bubble {
    max-width: 85%;
    padding: 8px 13px;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    background: var(--bubble);
    border-radius: 16px 16px 4px 16px;
  }
  .bubble.unseen,
  .pictures.unseen {
    opacity: 0.6;
  }
  .pictures {
    display: flex;
    flex-wrap: wrap;
    justify-content: flex-end;
    gap: 6px;
    max-width: 85%;
  }
  .pictures a {
    display: block;
    line-height: 0;
  }
  .pictures img {
    width: auto;
    max-width: 220px;
    height: auto;
    max-height: 160px;
    object-fit: cover;
    border-radius: 12px;
  }
  .failed .bubble {
    box-shadow: inset 0 0 0 1px color-mix(in oklab, var(--danger) 50%, transparent);
  }
  .problem {
    color: var(--danger);
    font-size: 11.5px;
  }
  .problem button {
    padding: 0 2px;
    color: var(--text);
    font: inherit;
    text-decoration: underline;
    background: none;
    border: 0;
    cursor: pointer;
  }
  .note {
    margin: 0;
    color: var(--muted);
    font-size: 12px;
    white-space: pre-wrap;
  }
  .live {
    display: flex;
    gap: 8px;
    min-width: 0;
    margin: 0;
    font-size: 12.5px;
  }
  .activity {
    min-width: 0;
    overflow: hidden;
    color: var(--muted);
    font-family: var(--mono);
    font-size: 11.5px;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .answer {
    margin-bottom: 8px;
    padding: 8px 12px 10px;
    background: var(--well);
    border-radius: 12px;
  }
  .answer header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    color: var(--muted);
    font-family: var(--mono);
    font-size: 12px;
  }
  .answer header button {
    padding: 0 4px;
    color: var(--faint);
    font-size: 16px;
    background: none;
    border: 0;
    cursor: pointer;
  }
  .answer pre {
    max-height: 220px;
    margin: 6px 0 0;
    overflow: auto;
    font-family: var(--mono);
    font-size: 12px;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }
  .answer.failed pre {
    color: var(--danger);
  }
  .dock {
    position: relative;
    display: flex;
    flex-direction: column;
    flex: none;
    width: 100%;
    max-width: 720px;
    margin: 0 auto;
    padding: 0 14px 14px;
  }
</style>
