<script lang="ts">
  import { tick } from 'svelte';
  import { boards } from './lib/boards.svelte';
  import Canvas from './lib/Canvas.svelte';
  import { ago, place, rank } from './lib/format';
  import { mac, shortcut, typing } from './lib/keys';
  import Palette, { type Item } from './lib/Palette.svelte';
  import { prefs } from './lib/prefs.svelte';
  import { busy } from './lib/live.svelte';
  import About from './lib/About.svelte';
  import { layout } from './lib/layout.svelte';
  import Gesture, { drawn } from './lib/Gesture.svelte';
  import NewSession from './lib/NewSession.svelte';
  import Phone from './lib/Phone.svelte';
  import Rail from './lib/Rail.svelte';
  import Settings from './lib/Settings.svelte';
  import { sessions } from './lib/sessions.svelte';
  import Tabs from './lib/Tabs.svelte';
  import { deleteArtifact, listArtifacts, type Artifact } from './lib/api';
  import { artifacts } from './lib/artifacts.svelte';

  const RAIL_KEY = 'albedo.rail';
  const MINIMAP_KEY = 'albedo.minimap';
  let railOpen = $state(localStorage.getItem(RAIL_KEY) !== 'closed');
  let minimap = $state(localStorage.getItem(MINIMAP_KEY) === 'on');
  let paletteOpen = $state(false);
  let settingsOpen = $state(false);
  let aboutOpen = $state(false);
  let newOpen = $state(false);
  let search = $state<HTMLInputElement>();
  /** The gallery of every artifact, in the palette: to open one, or to delete one. */
  let gallery = $state<'open' | 'delete' | null>(null);
  let shelf = $state<Artifact[]>([]);

  // The palette finds artifacts too, so the list is read whenever it opens.
  $effect(() => {
    if (paletteOpen || gallery) listArtifacts().then((found) => (shelf = found), () => {});
  });

  $effect(() => localStorage.setItem(RAIL_KEY, railOpen ? 'open' : 'closed'));
  $effect(() => localStorage.setItem(MINIMAP_KEY, minimap ? 'on' : 'off'));

  // With the sessions hidden, the pointer at the canvas's edge on their side
  // brings them out floating over it, at once. How near counts as the edge
  // grows with how fast the pointer is heading there, so a flick toward the
  // edge opens it early and a slow drift along the canvas only right at it.
  // It is watched from the canvas rather than a strip along the edge, so the
  // edge still pans and clicks like the rest of the canvas. Out, the card
  // stays while the pointer is on it or near it (the top bar above it
  // included, for an overshoot toward the first rows), while its filter has
  // focus, and goes soon after the pointer is clearly elsewhere or leaves
  // the page.
  const PEEK_EDGE = 20;
  const PEEK_FLICK_EDGE = 50;
  /** px of edge gained per px/ms of speed toward it */
  const PEEK_PER_SPEED = 15;
  const PEEK_NEAR = 48;
  const PEEK_LINGER_MS = 100;
  let peek = $state(false);
  let peekEl = $state<HTMLElement>();
  /** The pointer's last distance from that edge, and its speed toward it, smoothed. */
  const heading = { x: 0, t: 0, speed: 0 };
  let peekTimer: ReturnType<typeof setTimeout> | undefined;
  let pointerNear = false;
  $effect(() => {
    if (railOpen) peek = false;
  });

  function edge(event: PointerEvent) {
    if (railOpen || peek) return;
    const canvas = (event.currentTarget as HTMLElement).getBoundingClientRect();
    const x = prefs.sidebarRight ? canvas.right - event.clientX : event.clientX - canvas.left;
    const dt = event.timeStamp - heading.t;
    const toward = dt > 0 && dt < 100 ? Math.max(0, (heading.x - x) / dt) : 0;
    heading.speed = heading.speed * 0.5 + toward * 0.5;
    heading.x = x;
    heading.t = event.timeStamp;
    const reach = Math.min(PEEK_FLICK_EDGE, PEEK_EDGE + heading.speed * PEEK_PER_SPEED);
    if (x <= reach && !event.buttons) peek = true;
  }

  function near(event: PointerEvent) {
    if (!peek || !peekEl) {
      pointerNear = false;
      return;
    }
    const card = peekEl.getBoundingClientRect();
    const beside = prefs.sidebarRight ? event.clientX >= card.left - PEEK_NEAR : event.clientX <= card.right + PEEK_NEAR;
    pointerNear = beside && event.clientY <= card.bottom + PEEK_NEAR;
    if (pointerNear) clearTimeout(peekTimer);
    else unpeek();
  }

  function unpeek() {
    clearTimeout(peekTimer);
    peekTimer = setTimeout(() => {
      // Typing in its filter keeps it out.
      if (!peekEl?.contains(document.activeElement)) peek = false;
    }, PEEK_LINGER_MS);
  }

  // The view controls show while the view moves and for a while after, then
  // fade; hovering or focusing them keeps them.
  const VIEW_LINGER_MS = 4000;
  // The keys the canvas answers that nothing on screen shows, as the
  // terminal's footer lists them: the key and the mouse gesture with it
  // (drawn, to keep the card short), then what it does.
  const canvasHints = [
    [['spc', 'grab'], 'pan'],
    [[mac ? '⌥' : 'alt', 'move'], 'move window'],
    [[mac ? 'cmd' : 'ctrl', 'scroll'], 'zoom'],
    [['⇧1'], 'fit all'],
    [['⌥←→'], 'windows'],
    [['spc', 'click', 'click'], 'zoom at'],
    [['click', 'click'], 'note'],
  ] as const;
  let viewShown = $state(false);
  /** The overview map is as wide as the controls it sits on. */
  let controlsWidth = $state(188);
  let viewTimer: ReturnType<typeof setTimeout> | undefined;
  /** Whether an event's target is in the overview map, which shows and fades with the controls. */
  function mapUnder(event: { target: EventTarget | null }) {
    return !!(event.target as Element | null)?.closest?.('.svelte-flow__minimap');
  }
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
    { label: 'open an artifact…', run: () => (gallery = 'open') },
    { label: 'delete an artifact…', run: () => (gallery = 'delete') },
  ];

  /** Opens an artifact beside the chat it came from, when that chat is on the board. */
  function openArtifact(artifact: Artifact) {
    const chat = `session:${artifact.session_id}`;
    const parent = boards.board?.nodes.some((node) => node.id === chat) ? chat : undefined;
    boards.board?.openArtifact(artifact.id, artifact.session_id, artifact.version, parent);
  }

  async function removeArtifact(artifact: Artifact) {
    await deleteArtifact(artifact.id);
    artifacts.forget(artifact.id);
    boards.board?.remove(`artifact:${artifact.id}`);
    shelf = shelf.filter((item) => item.id !== artifact.id);
  }

  function artifactItems(query: string, deleting = false): Item[] {
    return rank(shelf, query, (artifact) => `${artifact.title} ${artifact.session_name ?? ''}`).map<Item>((artifact) => ({
      key: `artifact:${artifact.id}`,
      kind: 'artifact',
      label: deleting ? `delete “${artifact.title}”` : artifact.title,
      detail: [
        artifact.versions > 1 ? `v${artifact.version}` : '',
        artifact.session_deleted ? 'from a deleted session' : artifact.session_name || place(artifact.workspace),
        ago(new Date(artifact.updated_at).toISOString()),
      ]
        .filter(Boolean)
        .join(' · '),
      run: () => (deleting ? removeArtifact(artifact) : openArtifact(artifact)),
    }));
  }

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
    return query ? [...found, ...artifactItems(query).slice(0, 20), ...actions] : [...actions, ...found];
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
      // A hidden sidebar comes out floating, held there by the filter's focus.
      if (!railOpen) peek = true;
      tick().then(() => search?.focus());
    } else return;
    event.preventDefault();
  }

  const linkLabel = { connecting: 'connecting', online: 'connected', offline: 'daemon unreachable', unauthorized: 'signed out: open the link albedo web printed' };
</script>

<svelte:window onkeydown={keydown} onpointermove={near} onmouseout={(event) => peek && !event.relatedTarget && ((pointerNear = false), unpeek())} />

{#if layout.phone}
  <Phone onsettings={() => (settingsOpen = !settingsOpen)} onnew={() => (newOpen = true)} />
{:else}
<div class="shell" class:rail-closed={!railOpen} class:right={prefs.sidebarRight}>
  <header class="topbar">
    <div class="start">
      <button class="icon rail-toggle" aria-label={railOpen ? 'Hide sessions' : 'Show sessions'} title="{railOpen ? 'Hide' : 'Show'} sessions ([)" onclick={() => (railOpen = !railOpen)}>
        <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><rect x="2" y="3" width="12" height="10" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.3" /><path d="M6.25 3v10" stroke="currentColor" stroke-width="1.3" /></svg>
        <kbd>[</kbd>
      </button>
      <span class="brand"><span class="spark" aria-hidden="true">✦</span> <span class="brand-ink">albedo</span></span>
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
      <button class="icon about" data-about-toggle aria-label="about albedo" aria-expanded={aboutOpen} title="about albedo" onclick={() => (aboutOpen = !aboutOpen)}>
        <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><circle cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="1.3" /><path d="M6.4 6.3a1.7 1.7 0 0 1 3.3.5c0 1.1-1.7 1.4-1.7 2.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" /><circle cx="8" cy="11.4" r="0.8" fill="currentColor" /></svg>
      </button>
      <button class="icon" class:on={settingsOpen} data-settings-toggle aria-label="Settings" aria-expanded={settingsOpen} title="Settings ({shortcut(',')})" onclick={() => (settingsOpen = !settingsOpen)}>
        <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="M2.5 5h6M11.5 5h2M2.5 11h2M7.5 11h6" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" /><circle cx="10" cy="5" r="1.6" fill="none" stroke="currentColor" stroke-width="1.3" /><circle cx="6" cy="11" r="1.6" fill="none" stroke="currentColor" stroke-width="1.3" /></svg>
      </button>
    </div>
  </header>

  {#if railOpen}<Rail bind:search onnew={() => (newOpen = true)} />{/if}

  <main
    class:quiet={!viewShown}
    onpointermovecapture={edge}
    onpointerover={(event) => mapUnder(event) && clearTimeout(viewTimer)}
    onpointerout={(event) => mapUnder(event) && !mapUnder({ target: event.relatedTarget }) && lingerView()}
  >
    {#if peek}
      <div
        class="peek"
        bind:this={peekEl}
        onfocusout={(event) => !pointerNear && !peekEl?.contains(event.relatedTarget as Node) && unpeek()}
      >
        <Rail bind:search onnew={() => (newOpen = true)} />
      </div>
    {/if}
    {#if boards.board}
      {#key boards.board}
        <Canvas board={boards.board} {minimap} mapWidth={controlsWidth} onpalette={() => (paletteOpen = true)} />
      {/key}
      <div class="view" class:shown={viewShown} onpointerenter={() => clearTimeout(viewTimer)} onpointerleave={lingerView} role="presentation">
        <p class="hints" aria-hidden="true">
          {#each canvasHints as [keys, does] (does)}
            <span class="hint">
              <kbd>
                {#each keys as key, at (at)}
                  {#if drawn(key)}<Gesture kind={key} />{:else}{key}{/if}
                {/each}
              </kbd>
              {does}
            </span>
          {/each}
        </p>
        <div class="controls" role="toolbar" aria-label="View" tabindex="-1" bind:offsetWidth={controlsWidth}>
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

{#if gallery}
  {#key gallery}
    <Palette
      placeholder={gallery === 'open' ? 'open an artifact…' : 'delete an artifact, for good…'}
      search={(query) => artifactItems(query, gallery === 'delete')}
      onclose={() => (gallery = null)}
    />
  {/key}
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
    grid-template-areas: 'start tabs link end';
    align-items: stretch;
    background: var(--rail);
  }
  .rail-closed .topbar {
    grid-template-columns: auto 1fr auto auto;
  }
  .topbar > :global(.tabs) {
    grid-area: tabs;
  }
  .link {
    grid-area: link;
  }
  .end {
    grid-area: end;
  }
  /* Mirrored: the sessions on the right, with their toggle and the brand
     above them, and search and settings on the left. */
  .shell.right {
    grid-template-columns: 1fr 264px;
  }
  .shell.right.rail-closed {
    grid-template-columns: 1fr;
  }
  .shell.right > :global(aside) {
    grid-area: 2 / 2;
  }
  .shell.right > main {
    grid-area: 2 / 1;
  }
  .right .topbar {
    grid-template-columns: auto 1fr auto 264px;
    grid-template-areas: 'end tabs link start';
  }
  .right.rail-closed .topbar {
    grid-template-columns: auto 1fr auto auto;
  }
  .right .start {
    flex-direction: row-reverse;
    padding: 0 10px 0 14px;
  }
  .right .end {
    padding: 0 6px 0 8px;
  }
  .right .rail-toggle svg {
    transform: scaleX(-1);
  }
  /* One control with its key, on the same surface as search. */
  .icon.rail-toggle {
    display: flex;
    align-items: center;
    gap: 6px;
    width: auto;
    padding: 0 5px 0 7px;
    background: var(--field);
  }
  /* A step of ink on the button, so the key reads as its own little surface. */
  .command kbd,
  .rail-toggle kbd {
    background: color-mix(in oklab, var(--text) 12%, transparent);
  }
  .start {
    display: flex;
    grid-area: start;
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
  .command:hover,
  .icon.rail-toggle:hover {
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
  .right .peek {
    right: 8px;
    left: auto;
  }
  /* Hidden, it lets clicks through to whatever window sits under it. */
  .view {
    visibility: hidden;
    opacity: 0;
    transition: opacity 600ms ease, visibility 0s linear 600ms;
    position: absolute;
    right: 14px;
    bottom: 14px;
    left: 14px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    /* The stretch between the hints and the controls is still canvas. */
    pointer-events: none;
  }
  .controls {
    display: flex;
    align-items: center;
    gap: 2px;
    pointer-events: auto;
    padding: 4px;
    background: var(--surface);
    border-radius: 12px;
    box-shadow: var(--shadow);
  }
  /* As the terminal's footer, the key standing out from what it does, each
     pair on a surface of its own beside the controls. */
  .hints {
    display: flex;
    align-items: center;
    gap: 6px;
    margin: 0;
    color: var(--muted);
    font-size: 12px;
    white-space: nowrap;
    pointer-events: none;
  }
  /* Centred rather than on a baseline: a key that is all drawing has none. */
  .hints .hint {
    display: flex;
    align-items: center;
    gap: 5px;
    height: 30px;
    padding: 0 10px;
    background: var(--surface);
    border-radius: 9px;
    box-shadow: var(--shadow);
  }
  .hints kbd {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    min-width: 0;
    height: auto;
    padding: 0;
    color: var(--text);
    font: inherit;
    background: none;
  }

  main :global(.svelte-flow__minimap) {
    transition: opacity 160ms ease, visibility 0s;
  }
  main.quiet :global(.svelte-flow__minimap) {
    visibility: hidden;
    opacity: 0;
    transition: opacity 600ms ease, visibility 0s linear 600ms;
  }
  @media (prefers-reduced-motion: reduce) {
    main :global(.svelte-flow__minimap) {
      transition: none !important;
    }
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
