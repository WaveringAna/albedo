<script lang="ts">
  import type { NodeProps } from '@xyflow/svelte';
  import type { Job } from '../api';
  import type { TerminalWindow } from '../board.svelte';
  import { headline } from '../jobs.svelte';
  import { sessions } from '../sessions.svelte';
  import TerminalView from '../views/TerminalView.svelte';
  import WindowFrame from './WindowFrame.svelte';

  // A background job's output beside the chat that started it, following
  // the job while it runs.
  let { id, data, selected }: NodeProps<TerminalWindow> = $props();
  const session = $derived(sessions.byId.get(data.sessionId));
  let job = $state<Job | null>(null);
</script>

<WindowFrame {id} selected={!!selected} title="terminal · {job ? headline(job.command) : session?.name || 'untitled session'}">
  <TerminalView sessionId={data.sessionId} jobId={data.job} onjob={(found) => (job = found)} />
</WindowFrame>
