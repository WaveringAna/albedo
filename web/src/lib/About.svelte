<script lang="ts">
  // A pane at the top left, under the (?) beside the wordmark: what albedo
  // is, who makes it, and whose work it is built on. Like settings, it is not
  // modal; Escape or a click elsewhere closes it.
  let { onclose }: { onclose: () => void } = $props();
  let pane = $state<HTMLElement>();

  const REPO = 'https://tangled.org/okami.mom/albedo';

  const people = [
    { name: 'ana', handle: 'okami.mom' },
    { name: 'dawn', handle: 'ptr.pet' },
    { name: 'aly', handle: 'aly.codes' },
  ];

  // What the web client is built on; THIRD_PARTY_NOTICES.md has the rest.
  const notices = [
    { name: 'Svelte', url: 'https://svelte.dev', license: 'MIT' },
    { name: 'Svelte Flow', url: 'https://svelteflow.dev', license: 'MIT' },
    { name: 'Diffs, from Pierre', url: 'https://diffs.com', license: 'Apache-2.0' },
    { name: 'Shiki', url: 'https://shiki.style', license: 'MIT' },
    { name: 'KaTeX', url: 'https://katex.org', license: 'MIT' },
    { name: 'Pele', url: 'https://pele.run', license: 'MIT' },
    { name: 'marked', url: 'https://marked.js.org', license: 'MIT' },
    { name: 'madoromi', url: 'https://madoromi.moonwit.ch/', license: 'MPL-2.0' },
  ];

  $effect(() => {
    const away = (event: PointerEvent) => {
      const target = event.target as HTMLElement;
      if (!pane?.contains(target) && !target.closest('[data-about-toggle]')) onclose();
    };
    const key = (event: KeyboardEvent) => event.key === 'Escape' && onclose();
    document.addEventListener('pointerdown', away, true);
    document.addEventListener('keydown', key);
    return () => {
      document.removeEventListener('pointerdown', away, true);
      document.removeEventListener('keydown', key);
    };
  });
</script>

<div class="pane" bind:this={pane} role="dialog" aria-label="about albedo">
  <header>
    <h2><span class="spark" aria-hidden="true">✦</span> albedo</h2>
    <p class="lead">a coding agent that lives in a daemon, with a terminal and a canvas to work with it.</p>
  </header>

  <section>
    <h3>made by</h3>
    <ul class="people">
      {#each people as person (person.handle)}
        <li>
          <span class="name">{person.name}</span>
          <a href="https://bsky.app/profile/{person.handle}" target="_blank" rel="noopener noreferrer">@{person.handle}</a>
        </li>
      {/each}
    </ul>
    <p class="note">
      and with thanks to everyone else whose care, fixes and ideas are in it too:
      <a href="{REPO}/commits/main" target="_blank" rel="noopener noreferrer">see every contributor on tangled</a>.
    </p>
  </section>

  <section>
    <h3>built on</h3>
    <ul class="notices">
      {#each notices as notice (notice.name)}
        <li>
          <a href={notice.url} target="_blank" rel="noopener noreferrer">{notice.name}</a>
          <span class="license">{notice.license}</span>
        </li>
      {/each}
    </ul>
    <p class="note">
      <a href="{REPO}/blob/main/THIRD_PARTY_NOTICES.md" target="_blank" rel="noopener noreferrer">all third party notices</a>
      · <a href={REPO} target="_blank" rel="noopener noreferrer">source</a>
    </p>
  </section>
</div>

<style>
  /* Under its button, wherever the top bar puts that. */
  :global([data-sidebar='right']) .pane {
    right: auto;
    left: 10px;
  }
  .pane {
    position: fixed;
    top: 50px;
    right: 10px;
    z-index: 50;
    display: grid;
    gap: 20px;
    width: 320px;
    max-height: calc(100vh - 64px);
    padding: 18px;
    overflow-y: auto;
    overscroll-behavior: contain;
    background: var(--surface);
    border-radius: 14px;
    box-shadow: var(--shadow-lg);
    scrollbar-width: thin;
  }
  h2 {
    margin: 0;
    font-size: 15px;
    font-weight: 620;
    letter-spacing: -0.01em;
  }
  .spark {
    color: var(--brand-from);
  }
  h3 {
    margin: 0 0 8px;
    font-size: 13px;
    font-weight: 600;
  }
  .lead {
    margin: 6px 0 0;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.45;
  }
  ul {
    display: grid;
    gap: 4px;
    margin: 0;
    padding: 0;
    list-style: none;
  }
  /* Each name sits right beside what belongs to it, so the eye never has
     to cross the pane to pair them. */
  li {
    display: flex;
    align-items: baseline;
    gap: 8px;
    font-size: 13px;
  }
  .name {
    font-weight: 560;
  }
  .license {
    color: var(--faint);
    font-size: 11.5px;
    font-variant-numeric: tabular-nums;
  }
  .note {
    margin: 10px 0 0;
    color: var(--muted);
    font-size: 12px;
    line-height: 1.45;
  }
  a {
    color: var(--accent);
    text-decoration: none;
  }
  a:hover {
    text-decoration: underline;
    text-underline-offset: 2px;
  }
</style>
