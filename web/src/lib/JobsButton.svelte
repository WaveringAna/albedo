<script lang="ts">
  import type { Job } from './api';
  import { ago } from './format';
  import { headline, outcome, watchJobs } from './jobs.svelte';
  import MenuButton from './MenuButton.svelte';

  // The session's background jobs: a terminal icon, with how many are
  // running, that lists them (finished ones too, while the kernel still has
  // their output). Nothing shows until the session has had a job.
  let { sessionId, onopen, up = false }: { sessionId: string; onopen: (job: string) => void; up?: boolean } = $props();
  let jobs = $state<Job[]>([]);
  let listed = $state(false);
  const running = $derived(jobs.filter((job) => job.state === 'running').length);

  $effect(() => watchJobs(sessionId, (found) => (jobs = found)));
</script>

{#if jobs.length}
  <MenuButton label="background jobs" count={running} live={running > 0} {up} bind:open={listed}>
    {#snippet icon()}
      <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true"><path d="M3 4.5l3.5 3.5L3 11.5M8 12h5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
    {/snippet}
    {#each jobs as job (job.id)}
      <li>
        <button onclick={() => ((listed = false), onopen(job.id))}>
          <span class="command" title={job.command}>{headline(job.command)}</span>
          <span class="outcome" class:running={job.state === 'running'} class:failed={job.state === 'exited' && (job.exit_code !== 0 || job.timed_out)}>{outcome(job)}</span>
          <span class="when">{ago(new Date(job.started_at).toISOString())}</span>
        </button>
      </li>
    {/each}
  </MenuButton>
{/if}

<style>
  .command {
    overflow: hidden;
    font-family: var(--mono);
    font-size: 12px;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .outcome {
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
