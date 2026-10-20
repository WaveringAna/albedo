<script lang="ts">
  import { boards } from './lib/boards.svelte';
  import Canvas from './lib/Canvas.svelte';
  import { ago, place, rank } from './lib/format';
  import { shortcut, typing } from './lib/keys';
  import Palette, { type Item } from './lib/Palette.svelte';
  import { prefs } from './lib/prefs.svelte';
  import { busy } from './lib/live.svelte';
  import About from './lib/About.svelte';
  import { layout } from './lib/layout.svelte';
  import NewSession from './lib/NewSession.svelte';
  import Phone from './lib/Phone.svelte';
  import Rail from './lib/Rail.svelte';
  import Settings from './lib/Settings.svelte';
  import { sessions } from './lib/sessions.svelte';
  import Tabs from './lib/Tabs.svelte';

  const RAIL_KEY = 'albedo.rail';
  const MINIMAP_KEY = 'albedo.minimap';
  let railOpen = $state(localStorage.getItem(RAIL_KEY) !== 'closed');
  let minimap = $state(localStorage.getItem(MINIMAP_KEY) === 'on');
  let paletteOpen = $state(false);
  let settingsOpen = $state(false);
  let aboutOpen = $state(false);
  let newOpen = $state(false);
  let search = $state<HTMLInputElement>();

  $effect(() => localStorage.setItem(RAIL_KEY, railOpen ? 'open' : 'closed'));

  // With the sessions hidden, the pointer at the canvas's left edge brings
  // them out floating over it, until it wanders past them or leaves the
  // canvas. It is watched from the canvas rather than a strip along the edge,
  // so the edge still pans and clicks like the rest of the canvas.
  const PEEK_EDGE = 20;
  const PEEK_WIDTH = 264;
  const PEEK_LINGER_MS = 20;
  let peek = $state(false);
  let peekEl = $state<HTMLElement>();
  let peekTimer: ReturnType<typeof setTimeout> | undefined;
  $effect(() => {
    if (railOpen) peek = false;
  });

  function edge(event: PointerEvent) {
    if (railOpen) return;
    const x = event.clientX - (event.currentTarget as HTMLElement).getBoundingClientRect().left;
    if (!peek) {
      if (x <= PEEK_EDGE && !event.buttons) peek = true;
    } else if (x > PEEK_WIDTH + 16) unpeek();
    else clearTimeout(peekTimer);
  }

  function unpeek() {
    clearTimeout(peekTimer);
    peekTimer = setTimeout(() => {
      // Typing in its filter keeps it out.
      if (!peekEl?.contains(document.activeElement)) peek = false;
    }, PEEK_LINGER_MS);
  }
  $effect(() => localStorage.setItem(MINIMAP_KEY, minimap ? 'on' : 'off'));

  // The view controls show while the view moves and for a while after, then
  // fade; hovering or focusing them keeps them.
  const VIEW_LINGER_MS = 4000;
  let viewShown = $state(false);
  let viewTimer: ReturnType<typeof setTimeout> | undefined;
  function lingerView() {
    viewShown = true;
    clearTimeout(viewTimer);
    viewTimer = setTimeout(() => (viewShown = false), VIEW_LINGER_MS);
  }
  $effect(() => {
    boards.board?.viewport;
    lingerView();
  });
  sessions.start();

  const commands: Omit<Item, 'kind' | 'key'>[] = [
    { label: 'new session', run: () => (newOpen = true) },
    { label: 'new board', run: () => boards.create() },
    { label: 'rename board', hint: 'F2', run: () => (boards.renaming = boards.active) },
    { label: 'next board', hint: '⇧]', run: () => boards.step(1) },
    { label: 'previous board', hint: '⇧[', run: () => boards.step(-1) },
    { label: 'close board tab', run: () => boards.active && boards.close(boards.active) },
    { label: 'delete board', run: () => boards.active && boards.delete(boards.active) },
    { label: 'new note', hint: 'N', run: () => boards.board?.noteAt() },
    { label: 'about albedo', run: () => (aboutOpen = true) },
    { label: 'fit all windows', hint: '⇧1', run: () => boards.board?.fit() },
    { label: 'zoom to 100%', hint: '⇧0', run: () => boards.board?.zoomTo(1) },
    { label: 'next window', hint: '⌥→', run: () => boards.board?.step(1) },
    { label: 'previous window', hint: '⌥←', run: () => boards.board?.step(-1) },
    { label: 'close window', run: () => closeSelected() },
    { label: 'toggle overview map', hint: 'M', run: () => (minimap = !minimap) },
    { label: 'toggle sessions', hint: '[', run: () => (railOpen = !railOpen) },
    { label: 'refresh sessions', run: () => sessions.refresh() },
    { label: 'settings', hint: '⌘,', run: () => (settingsOpen = true) },
    { label: 'theme: follow the system', run: () => (prefs.theme = 'system') },
    { label: 'theme: light', run: () => (prefs.theme = 'light') },
    { label: 'theme: dark', run: () => (prefs.theme = 'dark') },
  ];

  function searchEverything(query: string): Item[] {
    const found = rank(
      sessions.list.filter((session) => !session.preferences.archived),
      query,
      (session) => `${session.name} ${place(session.workspace)}`,
    )
      .slice(0, 60)
      .map<Item>((session) => ({
        key: session.id,
        kind: 'session',
        label: session.name || 'untitled session',
        detail: `${place(session.workspace)} · ${busy(session) ? 'working' : ago(session.activity_at)}`,
        run: () => boards.openSession(session),
      }));
    const reopen = boards.closed.map((entry) => ({ label: `open board: ${entry.name}`, run: () => boards.show(entry.id) }));
    const actions = rank([...commands, ...reopen], query, (command) => command.label).map<Item>((command) => ({ key: `command:${command.label}`, kind: 'command', ...command }));
    return query ? [...found, ...actions] : [...actions, ...found];
  }

  /** Zooms in or out by 5 points, landing on a multiple of 5. */
  function zoomStep(by: 1 | -1) {
    const board = boards.board;
    if (!board) return;
    const percent = Math.round(board.viewport.zoom * 100);
    const next = by > 0 ? Math.floor(percent / 5) * 5 + 5 : Math.ceil(percent / 5) * 5 - 5;
    board.zoomTo(next / 100);
  }

  function closeSelected() {
    const selected = boards.board?.nodes.find((node) => node.selected);
    if (selected) boards.board?.remove(selected.id);
  }

  function keydown(event: KeyboardEvent) {
    if ((event.metaKey || event.ctrlKey) && event.key === ',') {
      event.preventDefault();
      settingsOpen = !settingsOpen;
      return;
    }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
      event.preventDefault();
      paletteOpen = !paletteOpen;
      return;
    }
    if (paletteOpen || typing(event) || event.metaKey || event.ctrlKey) return;
    if (event.altKey) {
      if (event.key === 'ArrowRight') boards.board?.step(1);
      else if (event.key === 'ArrowLeft') boards.board?.step(-1);
      else return;
      return event.preventDefault();
    }
    if (event.key === '[') railOpen = !railOpen;
    else if (event.key === '{') boards.step(-1);
    else if (event.key === '}') boards.step(1);
    else if (event.key === 'F2') boards.renaming = boards.active;
    else if (event.key === '!' && event.code === 'Digit1') boards.board?.fit();
    else if (event.key === ')' && event.code === 'Digit0') boards.board?.zoomTo(1);
    else if (event.key === 'm') minimap = !minimap;
    else if (event.key === 'n') boards.board?.noteAt();
    else if (event.key === '+' || event.key === '=') zoomStep(1);
    else if (event.key === '-' || event.key === '_') zoomStep(-1);
    else if (event.key === '/') {
      railOpen = true;
      queueMicrotask(() => search?.focus());
    } else return;
    event.preventDefault();
  }

  const linkLabel = { connecting: 'connecting', online: 'connected', offline: 'daemon unreachable', unauthorized: 'signed out: open the link albedo web printed' };
</script>

<svelte:window onkeydown={keydown} />

{#if layout.phone}
  <Phone onsettings={() => (settingsOpen = !settingsOpen)} onnew={() => (newOpen = true)} />
{:else}
<div class="shell" class:rail-closed={!railOpen}>
  <header class="topbar">
    <div class="start">
      <button class="icon" aria-label={railOpen ? 'Hide sessions' : 'Show sessions'} title="{railOpen ? 'Hide' : 'Show'} sessions ([)" onclick={() => (railOpen = !railOpen)}>
        <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><rect x="2" y="3" width="12" height="10" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.3" /><path d="M6.25 3v10" stroke="currentColor" stroke-width="1.3" /></svg>
      </button>
      <span class="brand"><span class="spark" aria-hidden="true">✦</span> <span class="brand-ink">albedo</span></span>
      <button class="icon about" data-about-toggle aria-label="about albedo" aria-expanded={aboutOpen} title="about albedo" onclick={() => (aboutOpen = !aboutOpen)}>
        <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.3" /><path d="M6.4 6.3a1.7 1.7 0 0 1 3.3.5c0 1.1-1.7 1.4-1.7 2.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" /><circle cx="8" cy="11.4" r="0.8" fill="currentColor" /></svg>
      </button>
    </div>
    <Tabs />
    {#if sessions.link !== 'online'}
      <span class="link" role="status">{linkLabel[sessions.link]}</span>
    {/if}
    <div class="end">
      <button class="command" onclick={() => (paletteOpen = true)}>
        <span>search</span>
        <kbd>{shortcut('K')}</kbd>
      </button>
      <button class="icon" class:on={settingsOpen} data-settings-toggle aria-label="Settings" aria-expanded={settingsOpen} title="Settings ({shortcut(',')})" onclick={() => (settingsOpen = !settingsOpen)}>
        <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="M2.5 5h6M11.5 5h2M2.5 11h2M7.5 11h6" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" /><circle cx="10" cy="5" r="1.6" fill="none" stroke="currentColor" stroke-width="1.3" /><circle cx="6" cy="11" r="1.6" fill="none" stroke="currentColor" stroke-width="1.3" /></svg>
      </button>
    </div>
  </header>

  {#if railOpen}<Rail bind:search onnew={() => (newOpen = true)} />{/if}

  <main onpointermovecapture={edge} onpointerleave={() => peek && unpeek()}>
    {#if peek}
      <div
        class="peek"
        bind:this={peekEl}
        onfocusout={(event) => !peekEl?.contains(event.relatedTarget as Node) && unpeek()}
      >
        <Rail bind:search onnew={() => (newOpen = true)} />
      </div>
    {/if}
    {#if boards.board}
      {#key boards.board}
        <Canvas board={boards.board} {minimap} onpalette={() => (paletteOpen = true)} />
      {/key}
      <div class="view" class:shown={viewShown} role="toolbar" aria-label="View" tabindex="-1" onpointerenter={() => clearTimeout(viewTimer)} onpointerleave={lingerView}>
        <button aria-label="Zoom out" title="Zoom out (−)" onclick={() => zoomStep(-1)}>
          <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M4 8h8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg>
        </button>
        <button class="level" title="Zoom to 100% (⇧0)" onclick={() => boards.board?.zoomTo(1)}>{Math.round((boards.board.viewport.zoom ?? 1) * 100)}%</button>
        <button aria-label="Zoom in" title="Zoom in (+)" onclick={() => zoomStep(1)}>
          <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M4 8h8M8 4v8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg>
        </button>
        <button aria-label="Fit all windows" title="Fit all windows (⇧1)" onclick={() => boards.board?.fit()}>
          <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M2.5 6V3.5a1 1 0 011-1H6M10 2.5h2.5a1 1 0 011 1V6M13.5 10v2.5a1 1 0 01-1 1H10M6 13.5H3.5a1 1 0 01-1-1V10" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" /></svg>
        </button>
        <button aria-label="Overview map" aria-pressed={minimap} title="Overview map (M)" class:on={minimap} onclick={() => (minimap = !minimap)}>
          <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><rect x="2" y="3" width="12" height="10" rx="2" fill="none" stroke="currentColor" stroke-width="1.3" /><rect x="4.5" y="5.5" width="4" height="3" rx="0.75" fill="currentColor" /></svg>
        </button>
      </div>
    {/if}
  </main>
</div>

{/if}

{#if settingsOpen}
  <Settings onclose={() => (settingsOpen = false)} />
{/if}

{#if newOpen}
  <NewSession onclose={() => (newOpen = false)} />
{/if}

{#if aboutOpen}
  <About onclose={() => (aboutOpen = false)} />
{/if}

{#if paletteOpen}
  <Palette placeholder="open a session or run a command…" search={searchEverything} onclose={() => (paletteOpen = false)} />
{/if}

<style>
  .shell {
    display: grid;
    grid-template-rows: 44px 1fr;
    grid-template-columns: 264px 1fr;
    height: 100%;
  }
  .shell.rail-closed {
    grid-template-columns: 1fr;
  }
  .topbar {
    display: grid;
    grid-column: 1 / -1;
    grid-template-columns: 264px 1fr auto auto;
    align-items: stretch;
    background: var(--rail);
  }
  .rail-closed .topbar {
    grid-template-columns: auto 1fr auto auto;
  }
  .start {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 14px 0 10px;
  }
  .brand {
    font-size: 14px;
    font-weight: 650;
    letter-spacing: -0.02em;
    white-space: nowrap;
  }
  .spark {
    color: var(--brand-from);
    font-size: 12px;
  }
  .icon,
  .command {
    align-self: center;
    color: var(--muted);
    font: inherit;
    background: none;
    border: 0;
    border-radius: 8px;
    cursor: pointer;
    transition: color 120ms ease, background-color 120ms ease;
  }
  .icon {
    display: grid;
    place-items: center;
    width: 30px;
    height: 30px;
    padding: 0;
  }
  .about {
    width: 24px;
    height: 24px;
    margin-left: -4px;
    color: var(--faint);
  }
  .end {
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 0 8px 0 6px;
  }
  .icon.on {
    color: var(--text);
    background: var(--selected);
  }
  .command {
    display: flex;
    align-items: center;
    gap: 12px;
    height: 30px;
    padding: 0 5px 0 12px;
    font-size: 13px;
    background: var(--field);
  }
  .icon:hover,
  .command:hover {
    color: var(--text);
    background: var(--hover);
  }
  .command:hover {
    background: var(--selected);
  }
  .link {
    align-self: center;
    color: var(--danger);
    font-size: 12px;
  }
  main {
    position: relative;
    min-width: 0;
    min-height: 0;
    overflow: hidden;
  }
  /* The hidden sessions, out over the canvas while the pointer is at its edge. */
  .peek {
    position: absolute;
    top: 8px;
    bottom: 8px;
    left: 8px;
    z-index: 20;
    display: flex;
    width: 264px;
    overflow: hidden;
    border-radius: 14px;
    box-shadow: var(--shadow-lg);
  }
  .peek > :global(aside) {
    flex: 1;
  }
  /* Hidden, it lets clicks through to whatever window sits under it. */
  .view {
    visibility: hidden;
    opacity: 0;
    transition: opacity 600ms ease, visibility 0s linear 600ms;
    position: absolute;
    left: 14px;
    bottom: 14px;
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 4px;
    background: var(--surface);
    border-radius: 12px;
    box-shadow: var(--shadow);
  }
  .view.shown,
  .view:focus-within {
    visibility: visible;
    opacity: 1;
    transition: opacity 160ms ease, visibility 0s;
  }
  @media (prefers-reduced-motion: reduce) {
    .view {
      transition: none;
    }
  }
  .view button {
    display: grid;
    place-items: center;
    min-width: 30px;
    height: 30px;
    padding: 0 6px;
    color: var(--muted);
    font: inherit;
    font-size: 12px;
    background: none;
    border: 0;
    border-radius: 8px;
    cursor: pointer;
    transition: background-color 120ms ease, color 120ms ease;
  }
  .view button:hover {
    color: var(--text);
    background: var(--hover);
  }
  .view button:active {
    transform: scale(0.95);
  }
  .view .on {
    color: var(--accent);
  }
  .view .level {
    min-width: 52px;
    font-variant-numeric: tabular-nums;
  }
</style>
