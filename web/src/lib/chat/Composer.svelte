<script lang="ts">
  // Enter sends, Shift-Enter starts a new line. A draft survives until it is sent.
  let { onsend, busy, placeholder = 'Message' }: { onsend: (text: string) => void; busy: boolean; placeholder?: string } = $props();
  let text = $state('');
  let field = $state<HTMLTextAreaElement>();
  const ready = $derived(text.trim().length > 0);

  function send() {
    if (!ready) return;
    onsend(text);
    text = '';
    field?.focus();
  }

  function keydown(event: KeyboardEvent) {
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      send();
    }
  }
</script>

<form class="composer" onsubmit={(event) => (event.preventDefault(), send())}>
  <textarea bind:this={field} bind:value={text} onkeydown={keydown} {placeholder} rows="1" spellcheck="true" aria-label="Message"></textarea>
  <div class="bar">
    <span class="hint">{busy ? 'working · a new message waits its turn' : ''}</span>
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
  .send:active:not(:disabled) {
    transform: scale(0.94);
  }
  .send:disabled {
    cursor: default;
    opacity: 0.25;
  }
</style>
