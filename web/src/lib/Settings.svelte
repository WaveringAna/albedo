<script lang="ts">
  import { ACCENTS, prefs, type Theme } from './prefs.svelte';

  // A pane at the top right, beside the button that opens it. It is not
  // modal: the board stays usable, and Escape or a click elsewhere closes it.
  let { onclose }: { onclose: () => void } = $props();
  let pane = $state<HTMLElement>();

  const themes: { id: Theme; label: string }[] = [
    { id: 'system', label: 'system' },
    { id: 'light', label: 'light' },
    { id: 'dark', label: 'dark' },
  ];

  $effect(() => {
    const away = (event: PointerEvent) => {
      const target = event.target as HTMLElement;
      if (!pane?.contains(target) && !target.closest('[data-settings-toggle]')) onclose();
    };
    const key = (event: KeyboardEvent) => event.key === 'Escape' && onclose();
    document.addEventListener('pointerdown', away, true);
    document.addEventListener('keydown', key);
    pane?.querySelector<HTMLElement>('[aria-checked="true"]')?.focus();
    return () => {
      document.removeEventListener('pointerdown', away, true);
      document.removeEventListener('keydown', key);
    };
  });

  /** Arrow keys move within a radio group, as native radios do. */
  function arrows<T>(event: KeyboardEvent, options: T[], current: T, choose: (value: T) => void) {
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key];
    if (!step) return;
    event.preventDefault();
    const next = options[(options.indexOf(current) + step + options.length) % options.length];
    choose(next);
    queueMicrotask(() => (event.currentTarget as HTMLElement | null)?.querySelector<HTMLElement>('[aria-checked="true"]')?.focus());
  }
</script>

<section class="pane" bind:this={pane} aria-label="Settings">
  <h2>settings</h2>

  <div class="group">
    <h3 id="theme-label">theme</h3>
    <div
      class="segmented"
      role="radiogroup"
      aria-labelledby="theme-label"
      tabindex="-1"
      onkeydown={(event) => arrows(event, themes.map((theme) => theme.id), prefs.theme, (id) => (prefs.theme = id))}
    >
      {#each themes as theme (theme.id)}
        <button role="radio" aria-checked={prefs.theme === theme.id} tabindex={prefs.theme === theme.id ? 0 : -1} onclick={() => (prefs.theme = theme.id)}>
          <span class="preview" data-preview={theme.id} aria-hidden="true"></span>
          {theme.label}
        </button>
      {/each}
    </div>
    <p class="note">{prefs.theme === 'system' ? `following your system, which is ${prefs.resolved} right now` : `always ${prefs.theme}`}</p>
  </div>

  <div class="group">
    <h3 id="accent-label">accent</h3>
    <div
      class="accents"
      role="radiogroup"
      aria-labelledby="accent-label"
      tabindex="-1"
      onkeydown={(event) => arrows(event, ACCENTS.map((accent) => accent.id), prefs.accent, (id) => (prefs.accent = id))}
    >
      {#each ACCENTS as accent (accent.id)}
        <button role="radio" aria-checked={prefs.accent === accent.id} tabindex={prefs.accent === accent.id ? 0 : -1} onclick={() => (prefs.accent = accent.id)}>
          <span class="swatch" data-accent={accent.id} aria-hidden="true"></span>
          {accent.label}
        </button>
      {/each}
    </div>
  </div>

  <div class="group">
    <label class="toggle">
      <span>
        <span class="label">dots on the canvas</span>
        <span class="note">a faint guide for panning. they fade out when you zoom out.</span>
      </span>
      <input type="checkbox" role="switch" bind:checked={prefs.dots} />
    </label>
  </div>
</section>

<style>
  .pane {
    position: fixed;
    top: 50px;
    right: 10px;
    z-index: 50;
    display: grid;
    gap: 20px;
    width: 300px;
    padding: 18px;
    background: var(--surface);
    border-radius: 14px;
    box-shadow: var(--shadow-lg);
  }
  h2 {
    margin: 0;
    font-size: 15px;
    font-weight: 620;
    letter-spacing: -0.01em;
  }
  h3 {
    margin: 0 0 8px;
    font-size: 13px;
    font-weight: 560;
  }
  .note {
    display: block;
    margin: 8px 0 0;
    color: var(--muted);
    font-size: 12px;
    line-height: 1.4;
  }
  .segmented {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 6px;
  }
  .segmented button,
  .accents button {
    display: flex;
    align-items: center;
    color: var(--text);
    font: inherit;
    font-size: 12.5px;
    background: var(--field);
    border: 0;
    border-radius: 10px;
    cursor: pointer;
    transition: background-color 120ms ease, box-shadow 120ms ease, transform 100ms ease-out;
  }
  .segmented button {
    flex-direction: column;
    gap: 6px;
    padding: 8px 6px 8px;
  }
  .segmented button:active,
  .accents button:active {
    transform: scale(0.97);
  }
  .segmented button:hover,
  .accents button:hover {
    background: var(--selected);
  }
  [aria-checked='true'] {
    box-shadow: 0 0 0 2px var(--accent);
  }
  /* Small pictures of each theme: a window on its ground. */
  .preview {
    width: 100%;
    height: 34px;
    border-radius: 6px;
    background:
      linear-gradient(#fff, #fff) 9px 9px / calc(100% - 18px) 100% no-repeat,
      #ebe9e4;
  }
  .preview[data-preview='dark'] {
    background:
      linear-gradient(#1f1e1d, #1f1e1d) 9px 9px / calc(100% - 18px) 100% no-repeat,
      #111110;
  }
  .preview[data-preview='system'] {
    background:
      linear-gradient(90deg, #fff 50%, #1f1e1d 50%) 9px 9px / calc(100% - 18px) 100% no-repeat,
      linear-gradient(90deg, #ebe9e4 50%, #111110 50%);
  }
  .accents {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 6px;
  }
  .accents button {
    gap: 8px;
    height: 34px;
    padding: 0 10px;
  }
  .swatch {
    width: 14px;
    height: 14px;
    background: var(--accent);
    border-radius: 50%;
  }
  .toggle {
    display: flex;
    align-items: flex-start;
    gap: 14px;
    cursor: pointer;
  }
  .toggle .label {
    font-size: 13px;
    font-weight: 560;
  }
  .toggle .note {
    margin-top: 2px;
  }
  /* The switch is the native checkbox, drawn as a track and a knob. */
  input[role='switch'] {
    flex: none;
    position: relative;
    width: 34px;
    height: 20px;
    margin: 1px 0 0;
    background: var(--field);
    border-radius: 10px;
    box-shadow: inset 0 0 0 1px var(--hover);
    cursor: pointer;
    appearance: none;
    transition: background-color 160ms ease;
  }
  input[role='switch']::after {
    content: '';
    position: absolute;
    top: 2px;
    left: 2px;
    width: 16px;
    height: 16px;
    background: #fff;
    border-radius: 50%;
    box-shadow: 0 1px 3px rgb(0 0 0 / 0.25);
    transition: transform 180ms cubic-bezier(0.23, 1, 0.32, 1);
  }
  input[role='switch']:checked {
    background: var(--accent);
  }
  input[role='switch']:checked::after {
    transform: translateX(14px);
  }
  input[role='switch']:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }
</style>
