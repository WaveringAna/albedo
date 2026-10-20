<script lang="ts">
  import Chat from './chat/Chat.svelte';
  import { layout } from './layout.svelte';
  import SessionPicker from './SessionPicker.svelte';
  import { sessions } from './sessions.svelte';

  // The client on a narrow screen: the session list, or one session's chat
  // filling the screen. A review opens inside the chat.
  let { onsettings, onnew }: { onsettings: () => void; onnew: () => void } = $props();
  const session = $derived(layout.session ? sessions.byId.get(layout.session) : undefined);

  // The way out of a chat is a drawer, not a gesture taken from the browser,
  // and the drawer and the composer are one surface: the handle above the
  // composer is the sheet's top edge, resting there when closed. Dragging it
  // up (or a quick swipe up from the composer) raises the sheet with the
  // finger while the composer fades into the search bar pinned in its place;
  // dragging it down from its grip, or from anywhere while its list is at the
  // top, lowers it. Let go and it settles open when past half (lowering: still
  // two thirds up) or flicked up, and otherwise sinks back into the composer.
  // A tap on the handle opens it; on the grip or the scrim, closes it.
  const FLICK = 0.4; // px per ms
  let drawer = $state(false);
  /** How far the sheet's top is above the bottom while it is shown, or null. */
  let raised = $state<number | null>(null);
  /** Where its top rests when closed: at the composer's handle. */
  let rest = $state(0);
  /** The gap between the composer's bottom edge and the page's. */
  let below = $state(0);
  let height = $state(0);
  let sheet = $state<HTMLElement>();
  let main = $state<HTMLElement>();
  let chat = $state<HTMLElement>();
  const progress = $derived(raised === null ? 0 : Math.min(1, Math.max(0, (raised - rest) / (height - rest || 1))));
  /** The composer and the search trade places over the first half of the way. */
  const swap = $derived(Math.min(1, progress / 0.5));
  const motion = { y: 0, t: 0, v: 0 };
  let start = 0;
  let tween = 0;

  // Only while closed: once shown, the handle rides with the sheet. The sheet
  // stands on the composer's bottom edge, not the page's, so it never reaches
  // under what floats there (Safari's toolbar) and its search lands exactly
  // where the composer was.
  function measure() {
    if (raised !== null) return;
    const pill = chat?.querySelector('.handle span')?.getBoundingClientRect();
    const dock = chat?.querySelector('.dock')?.getBoundingClientRect();
    if (!pill || !dock || !main) return;
    below = Math.max(0, main.getBoundingClientRect().bottom - dock.bottom);
    // The grip's middle is 14px below the sheet's top; meet the pill's there.
    rest = dock.bottom - (pill.top + pill.height / 2 - 14);
  }

  function begin(y: number, t: number) {
    cancelAnimationFrame(tween);
    Object.assign(motion, { y, t, v: 0 });
    measure();
    start = raised ?? rest;
  }

  function follow(y: number, t: number) {
    if (t > motion.t) motion.v = (y - motion.y) / (t - motion.t);
    Object.assign(motion, { y, t });
  }

  function hold(to: number) {
    raised = Math.max(rest, Math.min(to, height || Infinity));
  }

  // Settling is a tween of the same number a finger moves, so the sheet, the
  // composer's fade and the scrim stay one motion.
  function settle(open: boolean) {
    drawer = open;
    cancelAnimationFrame(tween);
    const was = raised ?? rest;
    const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
    let t0 = 0;
    const frame = (now: number) => {
      // A sheet mounted by this very tap has no height until its first layout.
      if (open && !height) return void (tween = requestAnimationFrame(frame));
      t0 ||= now;
      const to = open ? height : rest;
      const t = still ? 1 : Math.min(1, (now - t0) / 260);
      raised = was + (to - was) * (1 - (1 - t) ** 3);
      if (t < 1) tween = requestAnimationFrame(frame);
      else if (!open) raised = null;
    };
    tween = requestAnimationFrame(frame);
  }

  let openedAt = 0;

  function open() {
    measure();
    raised ??= rest;
    openedAt = performance.now();
    settle(true);
  }

  // The click that ends a tap on the handle lands on the grip now under the
  // finger; it must not close what the tap just opened.
  function tapClose(event: MouseEvent) {
    if (event.timeStamp - openedAt > 350) settle(false);
  }

  function letGo(t: number) {
    // A finger that stopped before letting go is not flicking.
    const v = t - motion.t > 100 ? 0 : motion.v;
    settle(v < -FLICK || (v <= FLICK && progress > (drawer ? 2 / 3 : 1 / 2)));
  }

  let grabbed = false;
  let from = 0;

  function grab(event: PointerEvent) {
    grabbed = true;
    from = event.clientY;
    begin(event.clientY, event.timeStamp);
    (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
  }

  function drag(event: PointerEvent) {
    if (!grabbed) return;
    follow(event.clientY, event.timeStamp);
    if (raised !== null || Math.abs(from - event.clientY) >= 4) hold(start + from - event.clientY);
  }

  function release(event: PointerEvent) {
    if (!grabbed) return;
    grabbed = false;
    // A tap opens it as surely as a pull does.
    if (raised === null) open();
    else letGo(event.timeStamp);
  }

  let lowering: { y: number; moved: boolean } | null = null;

  function lowerStart(event: TouchEvent, fromHandle: boolean) {
    const list = sheet?.querySelector('.scroll');
    if (!fromHandle && list && list.scrollTop > 0) return;
    lowering = { y: event.touches[0].clientY, moved: false };
    begin(event.touches[0].clientY, event.timeStamp);
  }

  function lowerMove(event: TouchEvent) {
    if (!lowering) return;
    const y = event.touches[0].clientY;
    const dy = y - lowering.y;
    if (!lowering.moved && dy < -4) return void (lowering = null);
    if (dy > 4) lowering.moved = true;
    if (lowering.moved) {
      follow(y, event.timeStamp);
      hold(start - Math.max(0, dy));
      if (event.cancelable) event.preventDefault();
    }
  }

  function lowerEnd(event: TouchEvent) {
    if (lowering?.moved) letGo(event.timeStamp);
    lowering = null;
  }

  // Not passive, so a drag that lowers the drawer does not also scroll the list.
  $effect(() => {
    const element = sheet;
    if (!element) return;
    element.addEventListener('touchmove', lowerMove, { passive: false });
    return () => element.removeEventListener('touchmove', lowerMove);
  });

  // A quick swipe up from the composer raises it too, unless it would scroll
  // a long draft, or follows a hold (that is selecting text).
  const SWIPE_WITHIN = 300;
  let pulling: { x: number; y: number; at: number; on: boolean } | null = null;

  function pullStart(event: TouchEvent) {
    const target = event.target as Element;
    if (!target.closest('.composer')) return;
    const field = target.closest('textarea');
    if (field && field.scrollTop + field.clientHeight < field.scrollHeight - 1) return;
    const touch = event.touches[0];
    pulling = { x: touch.clientX, y: touch.clientY, at: event.timeStamp, on: false };
    begin(touch.clientY, event.timeStamp);
  }

  function pullMove(event: TouchEvent) {
    if (!pulling) return;
    const touch = event.touches[0];
    const up = pulling.y - touch.clientY;
    const across = Math.abs(touch.clientX - pulling.x);
    if (!pulling.on) {
      if (up < 8 && across < 8) return;
      if (up < 8 || across > up || event.timeStamp - pulling.at > SWIPE_WITHIN) return void (pulling = null);
      pulling.on = true;
    }
    follow(touch.clientY, event.timeStamp);
    hold(start + up);
    if (event.cancelable) event.preventDefault();
  }

  function pullEnd(event: TouchEvent) {
    if (pulling?.on) letGo(event.timeStamp);
    pulling = null;
  }

  $effect(() => {
    const element = chat;
    if (!element) return;
    const listening = new AbortController();
    const { signal } = listening;
    element.addEventListener('touchstart', pullStart, { signal });
    element.addEventListener('touchmove', pullMove, { signal, passive: false });
    element.addEventListener('touchend', pullEnd, { signal });
    element.addEventListener('touchcancel', pullEnd, { signal });
    return () => listening.abort();
  });

  // Choosing a session in the drawer closes it.
  $effect(() => {
    layout.session;
    cancelAnimationFrame(tween);
    drawer = false;
    raised = null;
  });
</script>

<div class="phone">
  {#if !layout.session}
  <header>
      <span class="brand"><span class="spark" aria-hidden="true">✦</span> albedo</span>
      <span class="spacer"></span>
      <button class="icon" data-settings-toggle aria-label="settings" onclick={onsettings}>
        <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="M2.5 5h6M11.5 5h2M2.5 11h2M7.5 11h6" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" /><circle cx="10" cy="5" r="1.6" fill="none" stroke="currentColor" stroke-width="1.3" /><circle cx="6" cy="11" r="1.6" fill="none" stroke="currentColor" stroke-width="1.3" /></svg>
      </button>
  </header>
  {/if}
  <main bind:this={main}>
    {#if layout.session}
      {#key layout.session}
        <div class="chat" bind:this={chat} class:covered={drawer} style:--composer={raised === null ? undefined : 1 - swap}>
          <Chat sessionId={layout.session} {session} windowId="phone:{layout.session}" inline>
            {#snippet handle()}
              <button
                class="handle"
                aria-label="sessions"
                aria-expanded={drawer}
                style:transform={raised === null ? undefined : `translateY(${rest - raised}px)`}
                onpointerdown={grab}
                onpointermove={drag}
                onpointerup={release}
                onpointercancel={() => grabbed && ((grabbed = false), settle(false))}
                onclick={(event) => event.detail === 0 && open()}
              ><span></span></button>
            {/snippet}
          </Chat>
        </div>
        {#if raised !== null}
          <button
            class="scrim"
            aria-label="close sessions"
            style:opacity={progress}
            style:--below="{below}px"
            style:pointer-events={drawer ? undefined : 'none'}
            onclick={tapClose}
          ></button>
          <div
            class="drawer"
            role="dialog"
            tabindex="-1"
            aria-label="sessions"
            bind:this={sheet}
            bind:offsetHeight={height}
            style:transform="translateY(calc(100% - {raised}px))"
            style:opacity={Math.min(1, progress / 0.12)}
            style:--hidden="{Math.max(0, height - raised)}px"
            style:--below="{below}px"
            style:--swap={swap}
            ontouchstart={(event) => lowerStart(event, !!(event.target as Element).closest('.grip'))}
            ontouchend={lowerEnd}
            ontouchcancel={lowerEnd}
          >
            <button class="handle grip" aria-label="close sessions" onclick={tapClose}><span></span></button>
            <SessionPicker {onnew} />
          </div>
        {/if}
      {/key}
    {:else}
      <SessionPicker {onnew} />
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
  main > :global(.sessions) {
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
    width: 48px;
    height: 8px;
    background: color-mix(in oklab, var(--text) 32%, var(--surface));
    border-radius: 4px;
  }
  .handle.grip {
    flex: none;
    height: 28px;
    margin: -6px 0 0;
  }
  /* The chat's handle floats over the end of the thread, just above the composer. */
  .chat .handle {
    position: absolute;
    right: 0;
    bottom: 100%;
    left: 0;
    width: 72px;
    height: 24px;
    margin: 0 auto;
    place-items: end center;
    padding-bottom: 5px;
  }
  .scrim {
    position: absolute;
    inset: 0 0 var(--below, 0px);
    z-index: 3;
    padding: 0;
    background: var(--scrim);
    border: 0;
  }
  /* It stands on the composer's bottom edge (--below up from the page's), and
     nothing of it shows past that line: not the part still below it while
     held, nor its shadow; the scrim stops there too, so what lies beneath
     stays the chat's own ground, the same as the sheet. */
  .drawer {
    position: absolute;
    inset: auto 0 var(--below, 0px);
    z-index: 4;
    display: flex;
    flex-direction: column;
    height: calc(82% - var(--below, 0px));
    padding-top: 6px;
    background: var(--surface);
    border-radius: 18px 18px 0 0;
    box-shadow: var(--shadow-lg);
    clip-path: inset(-120px 0 var(--hidden, 0px) 0);
  }
  .drawer > :global(.sessions) {
    flex: 1;
    min-height: 0;
  }
  /* The search stays where the composer is while the sheet slides, and comes
     in as the composer goes: its band, solid so the list never shows through,
     turns from the chat's ground to its own tone, and the field fades in. */
  .drawer :global(.bottom) {
    position: relative;
    background: color-mix(in oklab, var(--surface), var(--bg) calc(var(--swap, 1) * 100%));
    transform: translateY(calc(-1 * var(--hidden, 0px)));
  }
  .drawer :global(.bottom > *) {
    opacity: var(--swap, 1);
  }
  /* The composer's dock sits over the sheet, fading as the sheet rises, and
     lets taps through to the search once it is open. */
  .chat :global(.dock) {
    z-index: 5;
    opacity: var(--composer, 1);
  }
  .chat.covered :global(.dock) {
    pointer-events: none;
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
