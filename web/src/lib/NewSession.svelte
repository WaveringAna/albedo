<script lang="ts">
  import { browse, createSession, models, profiles, recentWorkspaces, type Directory, type Model, type Profile, type RecentWorkspace } from './api';
  import { boards } from './boards.svelte';
  import { homePath, rank } from './format';
  import { sessions } from './sessions.svelte';

  // Starting a session: pick its folder (one used before, a typed path, or
  // browsed to), then the provider, model and effort, which default to the
  // provider's own. A dialog on the canvas, the whole screen on a phone.
  let { onclose }: { onclose: () => void } = $props();

  let recent = $state<RecentWorkspace[]>([]);
  let query = $state('');
  let folder = $state<string | null>(null);
  let listing = $state<Directory | null>(null);
  let all = $state<Profile[]>([]);
  let profile = $state<string | null>(null);
  let catalogue = $state<Model[]>([]);
  let model = $state<string | null>(null);
  let effort = $state<string | null>(null);
  let problem = $state('');
  let starting = $state(false);
  let dialog = $state<HTMLDialogElement>();

  const chosen = $derived(all.find((candidate) => candidate.id === profile));
  const efforts = $derived(catalogue.find((candidate) => candidate.id === model)?.efforts ?? []);
  const shown = $derived(rank(recent, query, (entry) => homePath(entry.location)).slice(0, 8));
  // A typed absolute or home path is a folder in itself.
  const typed = $derived(/^(~|\/|[\w.-]+@?[\w.-]*:)/.test(query.trim()) ? query.trim() : null);

  $effect(() => {
    dialog?.showModal();
    recentWorkspaces().then((found) => (recent = found)).catch(() => {});
    profiles()
      .then(({ fallback, profiles }) => {
        all = profiles;
        profile = fallback ?? profiles[0]?.id ?? null;
      })
      .catch((error) => (problem = String(error.message ?? error)));
  });

  // A new provider brings its own model list, starting on its default model and effort.
  $effect(() => {
    const id = profile;
    if (!id) return;
    model = chosen?.model ?? null;
    effort = chosen?.effort ?? null;
    models(id)
      .then((found) => {
        if (profile !== id) return;
        catalogue = found;
        if (!model || !found.some((candidate) => candidate.id === model)) model = found[0]?.id ?? model;
      })
      .catch(() => (catalogue = []));
  });

  async function open(location: string) {
    problem = '';
    try {
      listing = await browse(location);
    } catch (error) {
      problem = String((error as Error).message ?? error);
    }
  }

  async function start() {
    if (!folder) return;
    starting = true;
    problem = '';
    try {
      const session = await createSession(folder, { provider_profile: profile, model, effort });
      await sessions.refresh();
      onclose();
      boards.openSession(session);
    } catch (error) {
      problem = String((error as Error).message ?? error);
    } finally {
      starting = false;
    }
  }
</script>

<dialog bind:this={dialog} onclose={onclose} onclick={(event) => event.target === dialog && onclose()} aria-label="new session">
  <form method="dialog" class="sheet" onsubmit={(event) => (event.preventDefault(), start())}>
    <h2>new session</h2>

    <section>
      <h3>folder</h3>
      {#if folder}
        <div class="picked">
          <span title={folder}>{homePath(folder)}</span>
          <button type="button" class="quiet" onclick={() => ((folder = null), (listing = null))}>change</button>
        </div>
      {:else if listing}
        <div class="browser">
          <div class="where">
            {#if listing.parent}<button type="button" class="quiet" onclick={() => open(listing!.parent!)} aria-label="up a folder">↑</button>{/if}
            <span title={listing.directory}>{homePath(listing.directory)}</span>
            <button type="button" class="use" onclick={() => (folder = listing!.directory)}>use this folder</button>
          </div>
          <ul>
            {#each listing.items.filter((item) => !item.hidden) as item (item.location)}
              <li><button type="button" onclick={() => open(item.location)}>{item.name}{#if item.vcs}<span class="vcs">{item.vcs}</span>{/if}</button></li>
            {/each}
          </ul>
        </div>
      {:else}
        <input bind:value={query} placeholder="a folder you've used, or a path" spellcheck="false" autocomplete="off" aria-label="folder" />
        <ul class="recent">
          {#if typed}
            <li><button type="button" onclick={() => open(typed!)}>{typed}<span class="hint">browse</span></button></li>
          {/if}
          {#each shown as entry (entry.location)}
            <li><button type="button" onclick={() => (folder = entry.location)}>{homePath(entry.location)}<span class="hint">{entry.use_count} {entry.use_count === 1 ? 'session' : 'sessions'}</span></button></li>
          {/each}
          <li><button type="button" class="quiet" onclick={() => open('~')}>browse from home…</button></li>
        </ul>
      {/if}
    </section>

    <section>
      <h3>model</h3>
      <div class="choices">
        <label>
          <span>provider</span>
          <select bind:value={profile}>
            {#each all as candidate (candidate.id)}<option value={candidate.id}>{candidate.id}</option>{/each}
          </select>
        </label>
        <label>
          <span>model</span>
          <select bind:value={model}>
            {#if model && !catalogue.some((candidate) => candidate.id === model)}<option value={model}>{model}</option>{/if}
            {#each catalogue as candidate (candidate.id)}<option value={candidate.id}>{candidate.label}</option>{/each}
          </select>
        </label>
      </div>
      {#if efforts.length}
        <div class="efforts" role="radiogroup" aria-label="effort">
          {#each efforts as option (option.id)}
            <button type="button" role="radio" aria-checked={effort === option.id} onclick={() => (effort = option.id)}>{option.label}</button>
          {/each}
        </div>
      {/if}
    </section>

    {#if problem}<p class="problem">{problem}</p>{/if}
    <footer>
      <button type="button" class="quiet" onclick={onclose}>cancel</button>
      <button type="submit" class="go" disabled={!folder || !profile || starting}>{starting ? 'starting…' : 'start'}</button>
    </footer>
  </form>
</dialog>

<style>
  dialog {
    width: min(460px, calc(100vw - 24px));
    max-height: calc(100dvh - 48px);
    padding: 0;
    color: var(--text);
    background: var(--surface);
    border: 0;
    border-radius: 16px;
    box-shadow: var(--shadow-lg);
  }
  dialog::backdrop {
    background: var(--scrim);
  }
  .sheet {
    display: grid;
    gap: 18px;
    padding: 18px;
  }
  h2 {
    margin: 0;
    font-size: 15px;
    font-weight: 620;
  }
  h3 {
    margin: 0 0 8px;
    color: var(--muted);
    font-size: 12px;
    font-weight: 560;
  }
  input,
  select {
    width: 100%;
    height: 34px;
    padding: 0 10px;
    color: var(--text);
    font: inherit;
    font-size: 13.5px;
    background: var(--field);
    border: 0;
    border-radius: 9px;
    outline: 0;
  }
  input:focus-visible,
  select:focus-visible {
    box-shadow: 0 0 0 2px var(--focus-ring);
  }
  ul {
    display: grid;
    gap: 1px;
    margin: 6px 0 0;
    padding: 0;
    list-style: none;
  }
  li button {
    display: flex;
    align-items: baseline;
    gap: 10px;
    width: 100%;
    padding: 7px 10px;
    color: var(--text);
    font: inherit;
    font-size: 13.5px;
    text-align: left;
    background: none;
    border: 0;
    border-radius: 8px;
    cursor: pointer;
  }
  li button:hover {
    background: var(--hover);
  }
  .hint,
  .vcs {
    color: var(--faint);
    font-size: 12px;
  }
  .browser ul {
    max-height: 260px;
    overflow-y: auto;
  }
  .where,
  .picked {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 4px 6px 10px;
    font-size: 13.5px;
    background: var(--well);
    border-radius: 9px;
  }
  .where span,
  .picked span {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .choices {
    display: grid;
    grid-template-columns: 1fr 1.6fr;
    gap: 8px;
  }
  .choices label {
    display: grid;
    gap: 4px;
    color: var(--faint);
    font-size: 11.5px;
  }
  .efforts {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    margin-top: 10px;
  }
  .efforts button {
    padding: 4px 10px;
    color: var(--text);
    font: inherit;
    font-size: 12.5px;
    background: var(--field);
    border: 0;
    border-radius: 999px;
    cursor: pointer;
  }
  .efforts [aria-checked='true'] {
    color: var(--surface);
    background: var(--accent);
  }
  .quiet {
    padding: 4px 10px;
    color: var(--muted);
    font: inherit;
    font-size: 12.5px;
    background: none;
    border: 0;
    border-radius: 8px;
    cursor: pointer;
  }
  .quiet:hover {
    color: var(--text);
    background: var(--hover);
  }
  .use {
    padding: 4px 10px;
    color: var(--surface);
    font: inherit;
    font-size: 12.5px;
    white-space: nowrap;
    background: var(--accent);
    border: 0;
    border-radius: 8px;
    cursor: pointer;
  }
  .problem {
    margin: 0;
    color: var(--danger);
    font-size: 12.5px;
  }
  footer {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
  }
  .go {
    height: 34px;
    padding: 0 18px;
    color: var(--surface);
    font: inherit;
    font-size: 13.5px;
    font-weight: 560;
    background: var(--accent);
    border: 0;
    border-radius: 10px;
    cursor: pointer;
  }
  .go:disabled {
    opacity: 0.4;
    cursor: default;
  }
  @media (max-width: 760px) {
    dialog {
      width: 100vw;
      max-width: 100vw;
      height: 100dvh;
      max-height: 100dvh;
      margin: 0;
      border-radius: 0;
    }
  }
</style>
