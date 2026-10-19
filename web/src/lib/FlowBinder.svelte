<script lang="ts">
  import { useSvelteFlow } from '@xyflow/svelte';
  import type { Board } from './board.svelte';

  // Renders nothing: it sits inside <SvelteFlow> so it can reach the flow's
  // helpers and hand them to the board while the board is on screen.
  let { board }: { board: Board } = $props();
  const flow = useSvelteFlow();

  $effect(() => {
    board.attach(flow);
    return () => board.detach();
  });
</script>
