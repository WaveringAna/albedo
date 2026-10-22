<script lang="ts">
  import { frameUrl } from '../api';
  import { artifacts, PageHost, pageHosts } from '../artifacts.svelte';
  import { boards } from '../boards.svelte';
  import { prefs } from '../prefs.svelte';
  import { tying } from '../tie.svelte';

  // One version of an artifact's page, live: the body of an artifact window
  // on the canvas and of the artifact that opens inside a chat on a phone.
  // The page runs sandboxed in a frame of its own (robot-docs/artifacts.md);
  // this answers its bridge, holds what the loop guard holds, and shows what
  // broke in it. `version` pins one version; null follows the newest, which
  // `latest` says is at least that. `windowId` is the canvas window it
  // fills, which notes tie into.
  let {
    windowId,
    artifactId,
    sessionId,
    latest = 0,
    version = null,
    reloads = 0,
    inline = false,
    onfailures,
  }: {
    windowId?: string;
    artifactId: string;
    sessionId: string;
    latest?: number;
    version?: number | null;
    /** Counts the reader's reloads; each one loads the page again. */
    reloads?: number;
    inline?: boolean;
    onfailures?: (failures: string[]) => void;
  } = $props();

  const READABLE = 0.6;

  let frame = $state<HTMLIFrameElement>();
  let loaded = $state(false);
  let asked = $state(false);

  const detail = $derived(artifacts.get(artifactId));
  const problem = $derived(artifacts.problem(artifactId));
  const shown = $derived(version ?? detail?.version ?? null);
  const entry = $derived(detail?.history.find((item) => item.version === shown)?.entry ?? detail?.entry ?? 'index.html');
  const url = $derived(detail && shown ? frameUrl(detail, shown, entry) : null);
  // The page's messages go to the session that made it, while it lives.
  const session = $derived(detail ? (detail.session_deleted ? null : detail.session_id) : sessionId);

  const host = new PageHost(
    () => frame,
    () => ({ title: detail?.title ?? 'artifact', version: shown ?? 1, session, theme: prefs.resolved }),
  );

  $effect(() => {
    artifacts.want(artifactId, latest);
  });

  $effect(() => {
    onfailures?.(host.failures);
  });

  $effect(() => {
    if (!windowId) return;
    pageHosts.set(windowId, host);
    return () => {
      if (pageHosts.get(windowId) === host) pageHosts.delete(windowId);
    };
  });

  $effect(() => {
    const receive = (event: MessageEvent) => host.receive(event);
    window.addEventListener('message', receive);
    return () => window.removeEventListener('message', receive);
  });

  // The page follows the client's colours: when the theme or palette changes,
  // after the client's own variables have.
  $effect(() => {
    prefs.resolved;
    JSON.stringify(prefs.palettes[prefs.resolved]);
    JSON.stringify(prefs.fonts);
    const frameId = requestAnimationFrame(() => host.notify('ui/notifications/host-context-changed', host.context()));
    return () => cancelAnimationFrame(frameId);
  });

  // A new version, or a reload, is a new page to wait for.
  $effect(() => {
    url;
    if (reloads) artifacts.read(artifactId);
    loaded = false;
    asked = false;
  });

  function started() {
    loaded = true;
    host.reset();
  }

  /** Asks the agent to look at what failed, with the page's own words. */
  async function askToFix() {
    if (!session || !detail || !shown) return;
    asked = true;
    const list = host.failures.map((failure) => `- ${failure}`).join('\n');
    await host.say(`The page failed:\n${list}\n\nartifacts.errors("${detail.id}") has the details.`).catch(() => (asked = false));
  }

  // Too small to use, the canvas is being moved, or a note's tie is drawn
  // over it: the page lets the pointer through, so the drag carries on over
  // it (the tie asks the page what it is over instead).
  const resting = $derived(((boards.board?.viewport.zoom ?? 1) < READABLE && !inline) || !!tying.note);
  const height = $derived(inline && host.height ? Math.min(Math.max(host.height, 160), window.innerHeight * 0.7) : null);
</script>

<div class="artifact" class:inline>
  {#if url}
    {#key `${url}#${reloads}`}
      <iframe
        bind:this={frame}
        src={url}
        title={detail?.title}
        sandbox="allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox allow-modals allow-downloads allow-pointer-lock"
        allow="fullscreen; clipboard-write"
        referrerpolicy="no-referrer"
        class:resting
        class:loaded
        style:height={height ? `${height}px` : null}
        onload={started}
      ></iframe>
    {/key}
    {#if !loaded}<p class="state">(・ω・)ﾉ opening the page…</p>{/if}
  {:else if problem}
    <p class="state">(・_・;) {problem}</p>
  {:else}
    <p class="state">(・ω・)ﾉ opening the page…</p>
  {/if}

  {#if host.failures.length}
    <aside class="failures" aria-live="polite">
      <span class="what" title={host.failures.join('\n')}>
        {host.failures.at(-1)}{#if host.failures.length > 1}<span class="more"> and {host.failures.length - 1} more</span>{/if}
      </span>
      {#if session}<button onclick={askToFix} disabled={asked}>{asked ? 'asked' : 'ask albedo to fix it'}</button>{/if}
    </aside>
  {/if}

  {#if host.held.length}
    <aside class="held" aria-live="polite">
      <span class="what" title={host.held.join('\n\n')}>
        this page wants to send {host.held.length === 1 ? 'a message' : `${host.held.length} messages`} by itself
      </span>
      <button class="quiet" onclick={() => host.discard()}>discard</button>
      <button onclick={() => host.release()}>send {host.held.length === 1 ? 'it' : 'them'}</button>
    </aside>
  {/if}
</div>

<style>
  .artifact {
    position: relative;
    display: flex;
    flex: 1;
    flex-direction: column;
    min-height: 0;
    background: var(--well);
  }
  iframe {
    flex: 1;
    width: 100%;
    min-height: 0;
    border: 0;
    background: var(--surface);
    opacity: 0;
    transition: opacity 160ms ease;
  }
  iframe.loaded {
    opacity: 1;
  }
  .inline iframe {
    flex: none;
    height: 320px;
  }
  iframe.resting,
  :global(.canvas:is(.hand, .panning, .carrying, .alt)) iframe,
  :global(.svelte-flow:has(.svelte-flow__node.dragging)) iframe {
    pointer-events: none;
  }
  .state {
    position: absolute;
    inset: 0;
    display: grid;
    place-content: center;
    margin: 0;
    color: var(--muted);
    font-size: 13px;
    pointer-events: none;
  }
  aside {
    display: flex;
    flex: none;
    align-items: center;
    gap: 8px;
    min-height: 40px;
    padding: 4px 8px 4px 16px;
    font-size: 12px;
    background: var(--title-bar);
  }
  .what {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    color: var(--muted);
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .failures .what {
    color: var(--danger);
  }
  .more {
    color: var(--muted);
  }
  aside button {
    flex: none;
    height: 26px;
    padding: 0 12px;
    color: var(--surface);
    font: inherit;
    background: var(--accent);
    border: 0;
    border-radius: 8px;
    cursor: pointer;
    transition: transform 120ms ease-out, opacity 120ms ease;
  }
  aside button:active {
    transform: scale(0.97);
  }
  aside button:disabled {
    opacity: 0.5;
    cursor: default;
  }
  aside button.quiet {
    color: var(--muted);
    background: none;
  }
  aside button.quiet:hover {
    color: var(--text);
    background: var(--hover);
  }
</style>
