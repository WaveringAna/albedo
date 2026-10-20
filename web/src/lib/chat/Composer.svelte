<script lang="ts">
  import { SvelteMap } from 'svelte/reactivity';
  import { attachable, marker, MAX_IMAGES, readImage, referenced, resolve, unmark, type Attached } from './attachments';

  // Enter sends, Shift-Enter starts a new line. A draft survives until it is
  // sent. Images come by paste, drop or the picker; each leaves a marker in
  // the text where it was attached.
  let {
    onsend,
    onpopout,
    onstop,
    busy,
    placeholder = 'message albedo…',
  }: { onsend: (text: string, images: Attached[]) => void; onpopout?: (text: string) => void; onstop?: () => Promise<void>; busy: boolean; placeholder?: string } = $props();
  let stopping = $state(false);

  async function stop() {
    if (!onstop || stopping) return;
    stopping = true;
    try {
      await onstop();
    } catch (error) {
      notice = `couldn't stop: ${(error as Error).message ?? error}`;
    } finally {
      stopping = false;
    }
  }
  let text = $state('');
  let field = $state<HTMLTextAreaElement>();
  let picker = $state<HTMLInputElement>();
  let dragging = $state(false);
  let notice = $state('');
  const images = new SvelteMap<number, Attached>();
  let next = 0;

  const marked = $derived(referenced(text, images));
  const ready = $derived(text.trim().length > 0 || marked.length > 0);

  function send() {
    if (!ready) return;
    const message = resolve(text, images);
    onsend(message.text, message.images);
    text = '';
    images.clear();
    next = 0;
    notice = '';
    field?.focus();
  }

  async function attach(files: Iterable<File>) {
    const chosen = [...files].filter(attachable);
    if (!chosen.length) return;
    const room = MAX_IMAGES - marked.length;
    notice = chosen.length > room ? `a message carries at most ${MAX_IMAGES} images` : '';
    for (const file of chosen.slice(0, Math.max(0, room))) {
      const image = await readImage(file);
      images.set(++next, image);
      insert(marker(next));
    }
  }

  /** Puts text at the cursor, spaced from its neighbours. */
  function insert(piece: string) {
    const at = field?.selectionStart ?? text.length;
    const end = field?.selectionEnd ?? at;
    const before = text.slice(0, at);
    const spaced = (before && !/\s$/.test(before) ? ' ' : '') + piece + ' ';
    text = before + spaced + text.slice(end);
    const cursor = at + spaced.length;
    queueMicrotask(() => field?.setSelectionRange(cursor, cursor));
  }

  function remove(n: number) {
    text = unmark(text, n);
    images.delete(n);
  }

  function keydown(event: KeyboardEvent) {
    // Escape in an empty field stops the turn, as in the terminal.
    if (event.key === 'Escape' && busy && !text) {
      event.preventDefault();
      stop();
      return;
    }
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      send();
    }
  }

  function paste(event: ClipboardEvent) {
    const files = [...(event.clipboardData?.files ?? [])].filter(attachable);
    if (!files.length) return;
    event.preventDefault();
    attach(files);
  }

  function drop(event: DragEvent) {
    dragging = false;
    if (!event.dataTransfer?.files.length) return;
    event.preventDefault();
    attach(event.dataTransfer.files);
  }
</script>

<form
  class="composer"
  class:dragging
  onsubmit={(event) => (event.preventDefault(), send())}
  ondragover={(event) => {
    if (!event.dataTransfer?.types.includes('Files')) return;
    event.preventDefault();
    dragging = true;
  }}
  ondragleave={() => (dragging = false)}
  ondrop={drop}
>
  {#if marked.length}
    <ul class="images" aria-label="attached images">
      {#each marked as n (n)}
        <li>
          <img src={images.get(n)!.preview} alt={marker(n)} />
          <span class="number">#{n}</span>
          <button type="button" class="drop" aria-label="remove image {n}" title="remove" onclick={() => remove(n)}>
            <svg viewBox="0 0 16 16" width="10" height="10" aria-hidden="true"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" /></svg>
          </button>
        </li>
      {/each}
    </ul>
  {/if}
  <textarea bind:this={field} bind:value={text} onkeydown={keydown} onpaste={paste} {placeholder} rows="1" spellcheck="true" aria-label="message"></textarea>
  <div class="bar">
    <button type="button" class="attach" aria-label="attach images" title="attach images (or paste, or drop)" onclick={() => picker?.click()}>
      <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true"><rect x="2" y="3" width="12" height="10" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.3" /><circle cx="6" cy="6.6" r="1.2" fill="currentColor" /><path d="M2.6 11.6 6 8.6l2.4 2 2.2-1.8 2.8 2.6" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round" /></svg>
    </button>
    <input
      bind:this={picker}
      type="file"
      accept="image/png,image/jpeg,image/gif,image/webp"
      multiple
      hidden
      onchange={(event) => {
        const input = event.currentTarget;
        attach(input.files ?? []).then(() => (input.value = ''));
      }}
    />
    {#if onpopout}
      <button
        type="button"
        class="attach"
        aria-label="pop out into a note"
        title="pop out into a note on the canvas"
        onclick={() => {
          onpopout(text);
          text = '';
        }}
      >
        <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true"><path d="M9 3h4v4M13 3 8 8M11.5 9.5V12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V5.5a1 1 0 0 1 1-1h2.5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" /></svg>
      </button>
    {/if}
    <span class="hint">{notice || (busy ? 'albedo is working · a new message waits its turn' : '')}</span>
    {#if busy && onstop}
      <button type="button" class="stop" disabled={stopping} aria-label="Stop" title="stop albedo (Esc)" onclick={stop}>
        <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><rect x="3.5" y="3.5" width="9" height="9" rx="2" fill="currentColor" /></svg>
      </button>
    {/if}
    <button type="submit" class="send" disabled={!ready} aria-label="Send" title="Send (Enter)">
      <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M8 13V3.5M3.5 8 8 3.5 12.5 8" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" /></svg>
    </button>
  </div>
</form>

<style>
  .composer {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 10px 10px 8px 14px;
    background: var(--field);
    border-radius: 16px;
    transition: box-shadow 120ms ease;
  }
  .composer:focus-within {
    box-shadow: 0 0 0 2px var(--focus-ring);
  }
  .composer.dragging {
    box-shadow: 0 0 0 2px var(--accent);
  }
  .images {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin: 0 0 6px;
    padding: 0;
    list-style: none;
  }
  .images li {
    position: relative;
  }
  .images img {
    display: block;
    width: 56px;
    height: 56px;
    object-fit: cover;
    border-radius: 8px;
  }
  .number {
    position: absolute;
    left: 4px;
    bottom: 4px;
    padding: 0 4px;
    color: #fff;
    font-size: 10px;
    background: rgb(0 0 0 / 0.5);
    border-radius: 4px;
  }
  .drop {
    position: absolute;
    top: -5px;
    right: -5px;
    display: grid;
    place-items: center;
    width: 18px;
    height: 18px;
    padding: 0;
    color: var(--surface);
    background: var(--text);
    border: 0;
    border-radius: 50%;
    cursor: pointer;
    opacity: 0;
    transition: opacity 120ms ease;
  }
  .images li:hover .drop,
  .drop:focus-visible {
    opacity: 1;
  }
  textarea {
    min-height: 22px;
    max-height: 240px;
    padding: 0;
    color: var(--text);
    font: inherit;
    font-size: 14px;
    line-height: 1.5;
    background: none;
    border: 0;
    outline: 0;
    resize: none;
    field-sizing: content;
    scrollbar-width: thin;
  }
  .bar {
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .attach {
    display: grid;
    place-items: center;
    width: 28px;
    height: 28px;
    margin-left: -6px;
    padding: 0;
    color: var(--muted);
    background: none;
    border: 0;
    border-radius: 8px;
    cursor: pointer;
    transition: background-color 120ms ease, color 120ms ease;
  }
  .attach:hover {
    color: var(--text);
    background: var(--hover);
  }
  .hint {
    flex: 1;
    color: var(--muted);
    font-size: 11.5px;
  }
  .send {
    display: grid;
    place-items: center;
    width: 28px;
    height: 28px;
    padding: 0;
    color: var(--surface);
    background: var(--text);
    border: 0;
    border-radius: 50%;
    cursor: pointer;
    transition: opacity 120ms ease, transform 120ms ease;
  }
  .stop {
    display: grid;
    place-items: center;
    width: 28px;
    height: 28px;
    padding: 0;
    color: var(--text);
    background: var(--well);
    border: 0;
    border-radius: 50%;
    cursor: pointer;
    transition: background-color 120ms ease, transform 120ms ease;
  }
  .stop:hover:not(:disabled) {
    color: var(--danger);
    background: color-mix(in oklab, var(--danger) 14%, var(--well));
  }
  .stop:active:not(:disabled) {
    transform: scale(0.94);
  }
  .stop:disabled {
    opacity: 0.5;
    cursor: default;
  }
  .send:active:not(:disabled) {
    transform: scale(0.94);
  }
  .send:disabled {
    cursor: default;
    opacity: 0.25;
  }
</style>
