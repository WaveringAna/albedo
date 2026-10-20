<script lang="ts">
  import Chat from './chat/Chat.svelte';
  import { layout } from './layout.svelte';
  import Rail from './Rail.svelte';
  import { sessions } from './sessions.svelte';

  // The client on a narrow screen: the session list, or one session's chat
  // filling the screen. A review opens inside the chat.
  let { onsettings, onpalette, onnew }: { onsettings: () => void; onpalette: () => void; onnew: () => void } = $props();
  const session = $derived(layout.session ? sessions.byId.get(layout.session) : undefined);

  // The way out of a chat is a drawer, not a gesture taken from the
  // browser: a handle above the composer, dragged up (or tapped), raises the
  // session list over the chat; dragged down, or a tap above it, lowers it.
  const OPEN_AT = 60;
  let drawer = $state(false);
  let lift = $state(0);
  let dragging = $state(false);
  let from = 0;

  function grab(event: PointerEvent) {
    from = event.clientY;
    dragging = true;
    lift = 0;
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
  }

  function drag(event: PointerEvent) {
    if (dragging) lift = Math.max(0, from - event.clientY);
  }

  function release() {
    if (!dragging) return;
    dragging = false;
    // A tap opens it as surely as a pull does.
    if (lift > OPEN_AT || lift < 6) drawer = true;
    lift = 0;
  }

  // Choosing a session in the drawer closes it.
  $effect(() => {
    layout.session;
    drawer = false;
  });
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
        <div class="chat">
          <Chat sessionId={layout.session} {session} windowId="phone:{layout.session}" inline>
            {#snippet handle()}
              <button
                class="handle"
                aria-label="sessions"
                aria-expanded={drawer}
                style:transform={lift ? `translateY(${-Math.min(lift, 120) / 3}px)` : undefined}
                onpointerdown={grab}
                onpointermove={drag}
                onpointerup={release}
                onpointercancel={() => ((dragging = false), (lift = 0))}
              ><span></span></button>
            {/snippet}
          </Chat>
        </div>
        {#if drawer}
          <button class="scrim" aria-label="close sessions" onclick={() => (drawer = false)}></button>
          <div class="drawer" role="dialog" aria-label="sessions">
            <button class="handle" aria-label="close sessions" onclick={() => (drawer = false)}><span></span></button>
            <Rail {onnew} />
          </div>
        {/if}
      {/key}
    {:else}
      <Rail {onnew} />
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
  .handle {
    display: grid;
    place-items: center;
    width: 100%;
    height: 18px;
    margin: 0 0 2px;
    padding: 0;
    background: none;
    border: 0;
    cursor: grab;
    touch-action: none;
  }
  .handle span {
    width: 38px;
    height: 5px;
    background: color-mix(in oklab, var(--text) 22%, transparent);
    border-radius: 3px;
  }
  .scrim {
    position: absolute;
    inset: 0;
    z-index: 3;
    padding: 0;
    background: var(--scrim);
    border: 0;
    animation: fade 180ms ease-out;
  }
  .drawer {
    position: absolute;
    inset: auto 0 0;
    z-index: 4;
    display: flex;
    flex-direction: column;
    height: 82%;
    padding-top: 6px;
    padding-bottom: env(safe-area-inset-bottom);
    background: var(--rail);
    border-radius: 18px 18px 0 0;
    box-shadow: var(--shadow-lg);
    animation: rise 240ms cubic-bezier(0.2, 0.8, 0.2, 1);
  }
  .drawer > :global(aside) {
    flex: 1;
    min-height: 0;
  }
  @keyframes rise {
    from {
      transform: translateY(100%);
    }
  }
  @keyframes fade {
    from {
      opacity: 0;
    }
  }
  @media (prefers-reduced-motion: reduce) {
    .drawer,
    .scrim {
      animation: none;
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
