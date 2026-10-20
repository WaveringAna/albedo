<script lang="ts">
  import type { Job } from './api';
  import { ago } from './format';
  import { headline, outcome, watchJobs } from './jobs.svelte';

  // The session's background jobs: a terminal icon, with how many are
  // running, that lists them (finished ones too, while the kernel still has
  // their output). Nothing shows until the session has had a job.
  let { sessionId, onopen, up = false }: { sessionId: string; onopen: (job: string) => void; up?: boolean } = $props();
  let jobs = $state<Job[]>([]);
  let listed = $state(false);
  let element = $state<HTMLElement>();
  const running = $derived(jobs.filter((job) => job.state === 'running').length);

  $effect(() => watchJobs(sessionId, (found) => (jobs = found)));

  $effect(() => {
    if (!listed) return;
    const away = (event: Event) => event.target instanceof Node && !element?.contains(event.target) && (listed = false);
    const escape = (event: KeyboardEvent) => event.key === 'Escape' && (listed = false);
    addEventListener('pointerdown', away, true);
    addEventListener('keydown', escape);
    return () => {
      removeEventListener('pointerdown', away, true);
      removeEventListener('keydown', escape);
    };
  });
</script>

{#if jobs.length}
  <span class="jobs nodrag" bind:this={element}>
    <button class="icon" class:live={running > 0} aria-expanded={listed} aria-label="background jobs" title="background jobs" onclick={() => (listed = !listed)}>
      <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true"><path d="M3 4.5l3.5 3.5L3 11.5M8 12h5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
      {#if running}<span class="count">{running}</span>{/if}
    </button>
    {#if listed}
      <ul class="list nowheel" class:up>
        {#each jobs as job (job.id)}
          <li>
            <button onclick={() => ((listed = false), onopen(job.id))}>
              <span class="command" title={job.command}>{headline(job.command)}</span>
              <span class="outcome" class:running={job.state === 'running'} class:failed={job.state === 'exited' && (job.exit_code !== 0 || job.timed_out)}>{outcome(job)}</span>
              <span class="when">{ago(new Date(job.started_at).toISOString())}</span>
            </button>
          </li>
        {/each}
      </ul>
    {/if}
  </span>
{/if}

<style>
  .jobs {
    position: relative;
    display: inline-flex;
  }
  .icon {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    height: 26px;
    padding: 0 7px;
    color: var(--muted);
    font: inherit;
    font-size: 12px;
    background: none;
    border: 0;
    border-radius: 8px;
    cursor: pointer;
    transition: background-color 120ms ease, color 120ms ease;
  }
  .icon:hover,
  .icon[aria-expanded='true'] {
    color: var(--text);
    background: var(--hover);
  }
  .icon.live {
    color: var(--accent);
  }
  .count {
    font-variant-numeric: tabular-nums;
  }
  .list {
    position: absolute;
    top: calc(100% + 6px);
    right: 0;
    z-index: 5;
    width: min(340px, 80vw);
    max-height: 260px;
    margin: 0;
    padding: 4px;
    overflow-y: auto;
    list-style: none;
    background: var(--surface);
    border-radius: 12px;
    box-shadow: var(--shadow-raised);
  }
  .list.up {
    top: auto;
    bottom: calc(100% + 6px);
    right: auto;
    left: 0;
  }
  li button {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto auto;
    align-items: baseline;
    gap: 10px;
    width: 100%;
    padding: 7px 10px;
    color: var(--text);
    font: inherit;
    font-size: 12.5px;
    text-align: left;
    background: none;
    border: 0;
    border-radius: 8px;
    cursor: pointer;
  }
  li button:hover {
    background: var(--hover);
  }
  .command {
    overflow: hidden;
    font-family: var(--mono);
    font-size: 12px;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .outcome,
  .when {
    color: var(--muted);
    font-size: 11.5px;
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
  }
  .outcome.running {
    color: var(--accent);
  }
  .outcome.failed {
    color: var(--danger);
  }
</style>
