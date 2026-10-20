<script lang="ts">
  import Chat from './chat/Chat.svelte';
  import { layout } from './layout.svelte';
  import Rail from './Rail.svelte';
  import { sessions } from './sessions.svelte';

  // The client on a narrow screen: the session list, or one session's chat
  // filling the screen. A review opens inside the chat.
  let { onsettings, onpalette }: { onsettings: () => void; onpalette: () => void } = $props();
  const session = $derived(layout.session ? sessions.byId.get(layout.session) : undefined);

  // No back button over a chat: a swipe to the right goes back to the list,
  // as the browser's own edge swipe and back gesture do. The chat follows the
  // finger, and a swipe that starts on something that scrolls sideways (a
  // diff, a table) is left to it.
  const BACK_AT = 90;
  let start: { x: number; y: number } | null = null;
  let pull = $state(0);
  let dragging = $state(false);

  function scrollsSideways(target: EventTarget | null) {
    for (let element = target as HTMLElement | null; element; element = element.parentElement) {
      if (element.scrollWidth > element.clientWidth + 1 && getComputedStyle(element).overflowX !== 'visible') return true;
    }
    return false;
  }

  function touchstart(event: TouchEvent) {
    const touch = event.touches[0];
    start = event.touches.length === 1 && !scrollsSideways(event.target) && !event.composedPath().some((element) => (element as Element).tagName === 'DIFFS-CONTAINER') ? { x: touch.clientX, y: touch.clientY } : null;
  }

  function touchmove(event: TouchEvent) {
    if (!start) return;
    const touch = event.touches[0];
    const dx = touch.clientX - start.x;
    const dy = touch.clientY - start.y;
    if (!dragging && (Math.abs(dy) > 12 || dx < -8)) return void (start = null);
    if (dx > 12 && Math.abs(dy) < dx / 2) dragging = true;
    if (dragging) pull = Math.max(0, dx * 0.8);
  }

  function touchend() {
    if (dragging && pull > BACK_AT) layout.back();
    start = null;
    dragging = false;
    pull = 0;
  }
</script>

<div class="phone">
  {#if !layout.session}
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
        <span class="peek" aria-hidden="true" style:opacity={Math.min(1, pull / BACK_AT)} class:ready={pull > BACK_AT}>‹ sessions</span>
        <div class="chat" role="region" aria-label="chat" style:transform={pull ? `translateX(${pull}px)` : undefined} class:settling={!dragging} ontouchstart={touchstart} ontouchmove={touchmove} ontouchend={touchend} ontouchcancel={touchend}>
          <Chat sessionId={layout.session} {session} windowId="phone:{layout.session}" inline />
        </div>
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
  .icon:active {
    background: var(--hover);
  }
  main {
    position: relative;
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
  .peek {
    position: absolute;
    top: 50%;
    left: 14px;
    color: var(--muted);
    font-size: 14px;
    transform: translateY(-50%);
    transition: color 120ms ease;
  }
  .peek.ready {
    color: var(--accent);
  }
  .chat.settling {
    transition: transform 200ms cubic-bezier(0.2, 0.8, 0.2, 1);
  }
  @media (prefers-reduced-motion: reduce) {
    .peek {
    position: absolute;
    top: 50%;
    left: 14px;
    color: var(--muted);
    font-size: 14px;
    transform: translateY(-50%);
    transition: color 120ms ease;
  }
  .peek.ready {
    color: var(--accent);
  }
  .chat.settling {
      transition: none;
    }
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
