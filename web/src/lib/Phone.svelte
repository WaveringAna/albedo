<script lang="ts">
  import Chat from './chat/Chat.svelte';
  import { layout } from './layout.svelte';
  import Rail from './Rail.svelte';
  import { sessions } from './sessions.svelte';

  // The client on a narrow screen: the session list, or one session's chat
  // filling the screen. A review opens inside the chat.
  let { onsettings, onpalette }: { onsettings: () => void; onpalette: () => void } = $props();
  const session = $derived(layout.session ? sessions.byId.get(layout.session) : undefined);
</script>

<div class="phone">
  {#if layout.session}
    <!-- No bar over a chat: one floating button back to the list, so the
         conversation has the whole screen. -->
    <button class="back" aria-label="back to sessions" title={session?.name || 'untitled session'} onclick={() => layout.back()}>
      <svg viewBox="0 0 16 16" width="18" height="18" aria-hidden="true"><path d="M10 3.5 5.5 8l4.5 4.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" /></svg>
    </button>
  {:else}
  <header>
      <span class="brand"><span class="spark" aria-hidden="true">✦</span> albedo</span>
      <span class="spacer"></span>
      <button class="icon" aria-label="search" onclick={onpalette}>
        <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" stroke-width="1.4" /><path d="M10.5 10.5 14 14" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" /></svg>
      </button>
      <button class="icon" data-settings-toggle aria-label="settings" onclick={onsettings}>
        <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="M2.5 5h6M11.5 5h2M2.5 11h2M7.5 11h6" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" /><circle cx="10" cy="5" r="1.6" fill="none" stroke="currentColor" stroke-width="1.3" /><circle cx="6" cy="11" r="1.6" fill="none" stroke="currentColor" stroke-width="1.3" /></svg>
      </button>
  </header>
  {/if}
  <main>
    {#if layout.session}
      {#key layout.session}
        <div class="chat"><Chat sessionId={layout.session} {session} windowId="phone:{layout.session}" inline /></div>
      {/key}
    {:else}
      <Rail />
    {/if}
  </main>
</div>

<style>
  .phone {
    position: relative;
    display: flex;
    flex-direction: column;
    height: 100dvh;
    background: var(--surface);
  }
  header {
    display: flex;
    align-items: center;
    gap: 6px;
    min-height: 48px;
    padding: 0 8px;
    padding-top: env(safe-area-inset-top);
    background: var(--surface);
  }
  .brand {
    padding-left: 6px;
    font-size: 15px;
    font-weight: 650;
  }
  .spark {
    color: var(--brand-from);
  }
  .spacer {
    flex: 1;
  }
  .icon {
    display: grid;
    place-items: center;
    width: 40px;
    height: 40px;
    padding: 0;
    color: var(--muted);
    background: none;
    border: 0;
    border-radius: 10px;
    cursor: pointer;
  }
  .back {
    position: absolute;
    top: calc(env(safe-area-inset-top) + 8px);
    left: 10px;
    z-index: 2;
    display: grid;
    place-items: center;
    width: 40px;
    height: 40px;
    padding: 0;
    color: var(--text);
    background: color-mix(in oklab, var(--surface) 80%, transparent);
    border: 0;
    border-radius: 50%;
    box-shadow: var(--shadow);
    backdrop-filter: blur(12px);
    cursor: pointer;
  }
  .back:active {
    transform: scale(0.95);
  }
  .icon:active {
    background: var(--hover);
  }
  main {
    display: flex;
    flex: 1;
    min-height: 0;
    flex-direction: column;
  }
  main > :global(aside) {
    flex: 1;
    width: 100%;
    min-height: 0;
  }
  .chat {
    padding-top: env(safe-area-inset-top);
    display: flex;
    flex: 1;
    min-height: 0;
    flex-direction: column;
    padding-bottom: env(safe-area-inset-bottom);
    background: var(--surface);
  }
</style>
