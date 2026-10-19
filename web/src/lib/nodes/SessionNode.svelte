<script lang="ts">
  import type { NodeProps } from '@xyflow/svelte';
  import type { SessionWindow } from '../board.svelte';
  import Chat from '../chat/Chat.svelte';
  import { place } from '../format';
  import LiveFace from '../LiveFace.svelte';
  import { sessions } from '../sessions.svelte';
  import WindowFrame from './WindowFrame.svelte';

  let { id, data, selected }: NodeProps<SessionWindow> = $props();
  const session = $derived(sessions.byId.get(data.sessionId));
  const working = $derived(session?.status?.phase === 'running');
</script>

<WindowFrame {id} selected={!!selected} title={session?.name || 'untitled session'}>
  {#snippet meta()}
    {#if working}<LiveFace {session} />{/if}
    {#if session}<span title={session.workspace}>{place(session.workspace)}</span>{/if}
  {/snippet}

  {#if session || !sessions.loaded}
    <Chat sessionId={data.sessionId} {session} />
  {:else}
    <p class="gone">(・_・;) this session is no longer on the daemon</p>
  {/if}
</WindowFrame>

<style>
  .gone {
    margin: 20px;
    color: var(--muted);
  }
</style>
