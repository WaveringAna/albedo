<script lang="ts">
  import { tick } from 'svelte';
  import { stopJob, type Job } from '../api';
  import { Tail, outcome, readable } from '../jobs.svelte';

  // One job's output, following it while it runs: the body of the terminal
  // window on the canvas and of the terminal that opens inside a chat on a
  // phone. It only reads; the one thing it does to the job is stop it.
  let { sessionId, jobId, onjob }: { sessionId: string; jobId: string; onjob?: (job: Job) => void } = $props();

  // svelte-ignore state_referenced_locally
  const tail = new Tail(sessionId, jobId);
  const shown = $derived(readable(tail.text));
  let scroller = $state<HTMLElement>();
  let pinned = true;
  let stopping = $state<'asking' | 'stopping' | null>(null);
  let problem = $state('');

  $effect(() => {
    tail.start();
    return () => tail.stop();
  });

  $effect(() => {
    if (tail.job) onjob?.(tail.job);
  });

  // Output arriving moves the view only for a reader who is at the end of it.
  $effect(() => {
    shown;
    if (pinned) tick().then(() => scroller && (scroller.scrollTop = scroller.scrollHeight));
  });

  function scrolled() {
    if (scroller) pinned = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 24;
  }

  async function stop() {
    if (stopping !== 'asking') {
      stopping = 'asking';
      setTimeout(() => stopping === 'asking' && (stopping = null), 3000);
      return;
    }
    stopping = 'stopping';
    problem = '';
    try {
      await stopJob(sessionId, jobId);
    } catch (error) {
      problem = String((error as Error).message ?? error);
    } finally {
      stopping = null;
    }
  }

</script>

<div class="terminal">
  <pre class="output nowheel" bind:this={scroller} onscroll={scrolled}>{#if tail.skipped}<span class="quiet">… {tail.skipped.toLocaleString()} earlier bytes not shown
</span>{/if}{shown}{#if !shown && !tail.problem && !tail.done}<span class="quiet">(・ω・)ﾉ waiting for output…</span>{:else if !shown && tail.done && !tail.problem}<span class="quiet">(・_・ ) this job wrote nothing</span>{/if}</pre>
  <footer>
    <span class="status" class:failed={tail.job?.state === 'exited' && (tail.job.exit_code !== 0 || tail.job.timed_out)}>{tail.job ? outcome(tail.job) : ''}</span>
    {#if tail.problem || problem}<span class="problem" title={tail.problem || problem}>{tail.problem || problem}</span>{/if}
    {#if tail.job?.state === 'running'}
      <button class="stop" disabled={stopping === 'stopping'} onclick={stop}>{stopping === 'asking' ? 'stop it?' : stopping === 'stopping' ? 'stopping…' : 'stop'}</button>
    {/if}
  </footer>
</div>

<style>
  .terminal {
    display: flex;
    flex: 1;
    flex-direction: column;
    min-height: 0;
  }
  .output {
    flex: 1;
    min-height: 0;
    margin: 0;
    padding: 12px 16px;
    overflow: auto;
    overscroll-behavior: contain;
    scrollbar-width: thin;
    color: var(--text);
    font-family: var(--mono);
    font-size: 12px;
    line-height: 1.5;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    background: var(--well);
  }
  .quiet {
    color: var(--muted);
  }
  footer {
    display: flex;
    flex: none;
    align-items: center;
    gap: 10px;
    min-height: 40px;
    padding: 0 12px 0 16px;
    background: var(--title-bar);
    font-size: 12px;
  }
  .status {
    color: var(--muted);
    font-variant-numeric: tabular-nums;
  }
  .status.failed,
  .problem {
    color: var(--danger);
  }
  .problem {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .stop {
    height: 26px;
    margin-left: auto;
    padding: 0 12px;
    color: var(--danger);
    font: inherit;
    background: none;
    border: 1px solid color-mix(in oklab, var(--danger) 45%, transparent);
    border-radius: 8px;
    cursor: pointer;
  }
  .stop:hover:not(:disabled) {
    background: color-mix(in oklab, var(--danger) 10%, transparent);
  }
  .stop:disabled {
    opacity: 0.5;
    cursor: default;
  }
</style>
