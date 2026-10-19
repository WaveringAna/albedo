<script lang="ts">
  import { onMount, tick } from 'svelte';
  import type { Session } from '../api';
  import LiveFace from '../LiveFace.svelte';
  import { face, formatElapsed } from '../moods';
  import { Transcript } from '../transcript.svelte';
  import Composer from './Composer.svelte';
  import Markdown from './Markdown.svelte';
  import WorkSteps from './WorkSteps.svelte';

  let { sessionId, session }: { sessionId: string; session: Session | undefined } = $props();

  // svelte-ignore state_referenced_locally
  const transcript = new Transcript(sessionId);
  const running = $derived(session?.status?.phase === 'running');
  $effect(() => {
    transcript.running = running;
  });
  let copied = $state<string | null>(null);

  async function copy(key: string, text: string) {
    await navigator.clipboard.writeText(text);
    copied = key;
    setTimeout(() => copied === key && (copied = null), 1400);
  }
  const last = $derived(transcript.groups.at(-1));
  const activity = $derived(session?.activity?.lines.findLast((line) => line.text.trim())?.text.trim() ?? '');

  let scroller = $state<HTMLElement>();
  let top = $state<HTMLElement>();
  let pinned = true;
  let settled = $state(false);
  let older = false;

  onMount(() => {
    transcript.load().then(async () => {
      await toBottom();
      settled = true;
    });
  });

  // Committed entries arrive by polling: quickly while the session works.
  $effect(() => {
    const every = running || transcript.pending.length ? 1200 : 5000;
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
    if (pinned) toBottom();
  });

  async function toBottom() {
    await tick();
    if (scroller) scroller.scrollTop = scroller.scrollHeight;
  }

  function scrolled() {
    if (scroller) pinned = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 40;
  }

  function send(text: string) {
    pinned = true;
    transcript.send(text);
  }
</script>

<div class="chat">
  <div class="scroller nowheel" bind:this={scroller} onscroll={scrolled}>
    <div class="thread">
      <div bind:this={top}></div>
      {#if transcript.loading}
        <p class="quiet">(・ω・)ﾉ reading the transcript…</p>
      {:else if transcript.error}
        <p class="quiet error">(｡•︿•｡) couldn't read the transcript: {transcript.error}</p>
      {:else if transcript.groups.length === 0}
        <p class="quiet">(˶ᵔ ᵕ ᵔ˶) nothing here yet. say hi below</p>
      {:else if transcript.more}
        <p class="quiet">earlier messages load as you scroll up</p>
      {/if}

      {#each transcript.groups as group (group.key)}
        {#if group.kind === 'user'}
          <div class="user" class:failed={group.state === 'failed'}>
            {#if group.from || group.gap}
              <span class="plate"><span class:you={!group.from}>{group.from ?? 'you'}</span>{#if group.gap}<span class="meta">{' · '}{group.gap}</span>{/if}</span>
            {/if}
            <div class="bubble" class:sending={group.state === 'sending'}>{group.text}</div>
            {#if group.state === 'failed'}
              <span class="problem">
                not sent: {group.error}
                <button onclick={() => transcript.retry(group.key.slice('pending:'.length))}>retry</button>
                <button onclick={() => transcript.discard(group.key.slice('pending:'.length))}>discard</button>
              </span>
            {/if}
          </div>
        {:else if group.kind === 'assistant'}
          <div class="assistant">
            {#if group.plate}<span class="plate agent">albedo</span>{/if}
            <Markdown text={group.text} />
          </div>
        {:else if group.kind === 'work'}
          <WorkSteps steps={group.steps} live={running && group === last} {transcript} {session} />
        {:else if group.kind === 'end'}
          <p class="end">
            <span class="face kaomoji" title={group.mood}>{face(group.mood, group.seed)}</span>
            <span class="meta">{[group.elapsedMs >= 1000 ? formatElapsed(group.elapsedMs) : '', group.tools ? `${group.tools} ${group.tools === 1 ? 'tool' : 'tools'}` : ''].filter(Boolean).join(' · ')}</span>
            {#if group.text}
              <button class="copy" onclick={() => copy(group.key, group.text)}>{copied === group.key ? 'copied' : 'copy'}</button>
            {/if}
          </p>
        {:else if group.kind === 'note'}
          <p class="note">{group.text}</p>
        {:else if group.kind === 'compaction'}
          <p class="note">{'(>_<)'} earlier context was compacted here</p>
        {/if}
      {/each}

      {#if running}
        <p class="live"><LiveFace {session} label />{#if activity}<span class="activity">{activity}</span>{/if}</p>
      {/if}
    </div>
  </div>

  <div class="dock">
    <Composer onsend={send} busy={running} />
  </div>
</div>

<style>
  .chat {
    display: flex;
    flex: 1;
    flex-direction: column;
    min-height: 0;
  }
  .scroller {
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
  .bubble {
    max-width: 85%;
    padding: 8px 13px;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    background: var(--bubble);
    border-radius: 16px 16px 4px 16px;
  }
  .bubble.sending {
    opacity: 0.6;
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
  .dock {
    flex: none;
    width: 100%;
    max-width: 720px;
    margin: 0 auto;
    padding: 0 14px 14px;
  }
</style>
