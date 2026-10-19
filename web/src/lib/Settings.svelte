<script lang="ts">
  import { ACCENTS, DEFAULTS, prefs, readPalette, SEASONS, type Mode, type Palette, type Theme } from './prefs.svelte';

  // A pane at the top right, beside the button that opens it. It is not
  // modal: the board stays usable, and Escape or a click elsewhere closes it.
  // Colours are edited per mode; the mode on screen is edited by default, so
  // every change shows at once.
  let { onclose }: { onclose: () => void } = $props();
  let pane = $state<HTMLElement>();
  let editing = $state<Mode>(prefs.resolved);
  let notice = $state('');

  const palette = $derived(prefs.palettes[editing]);
  // Choosing a theme edits the colours of the mode it shows.
  $effect(() => {
    editing = prefs.resolved;
  });
  const themes: { id: Theme; label: string }[] = [
    { id: 'system', label: 'system' },
    { id: 'light', label: 'light' },
    { id: 'dark', label: 'dark' },
  ];
  const fields: { key: 'accent' | 'background' | 'foreground'; label: string }[] = [
    { key: 'accent', label: 'accent' },
    { key: 'background', label: 'background' },
    { key: 'foreground', label: 'foreground' },
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

  function set(change: Partial<Palette>) {
    prefs.palettes[editing] = { ...palette, ...change };
  }

  /** A typed hex applies once it is whole; anything else waits, and blur shows the current value again. */
  function typed(key: 'accent' | 'background' | 'foreground', value: string) {
    const hex = value.trim().startsWith('#') ? value.trim() : `#${value.trim()}`;
    if (/^#[0-9a-f]{6}$/i.test(hex)) set({ [key]: hex.toLowerCase() });
  }

  function say(text: string) {
    notice = text;
    setTimeout(() => notice === text && (notice = ''), 2200);
  }

  async function copyTheme() {
    await navigator.clipboard.writeText(JSON.stringify({ light: prefs.palettes.light, dark: prefs.palettes.dark }, null, 2));
    say('copied both modes (˶ᵔ ᵕ ᵔ˶)');
  }

  async function pasteTheme() {
    try {
      const given = JSON.parse(await navigator.clipboard.readText());
      // A whole theme has both modes; a lone palette is for the mode being edited.
      if (given?.light || given?.dark) {
        if (given.light) prefs.palettes.light = readPalette(given.light, 'light');
        if (given.dark) prefs.palettes.dark = readPalette(given.dark, 'dark');
      } else prefs.palettes[editing] = readPalette(given, editing);
      say('theme pasted ✧');
    } catch {
      say("the clipboard isn't a theme (・_・;)");
    }
  }

  /** Arrow keys move within a radio group, as native radios do. */
  function arrows<T>(event: KeyboardEvent, options: T[], current: T, choose: (value: T) => void) {
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key];
    if (!step) return;
    event.preventDefault();
    choose(options[(options.indexOf(current) + step + options.length) % options.length]);
    queueMicrotask(() => (event.currentTarget as HTMLElement | null)?.querySelector<HTMLElement>('[aria-checked="true"]')?.focus());
  }
</script>

<section class="pane" bind:this={pane} aria-label="Settings">
  <h2>settings</h2>

  <div class="group">
    <h3 id="theme-label">theme</h3>
    <div class="themes" role="radiogroup" aria-labelledby="theme-label" tabindex="-1" onkeydown={(event) => arrows(event, themes.map((theme) => theme.id), prefs.theme, (id) => (prefs.theme = id))}>
      {#each themes as theme (theme.id)}
        <button role="radio" aria-checked={prefs.theme === theme.id} tabindex={prefs.theme === theme.id ? 0 : -1} onclick={() => (prefs.theme = theme.id)}>
          <span class="preview" aria-hidden="true">
            {#each theme.id === 'system' ? (['light', 'dark'] as const) : [theme.id as Mode] as mode (mode)}
              <span class="half" style:--bg={prefs.palettes[mode].background} style:--ink={prefs.palettes[mode].foreground} style:--tint={prefs.palettes[mode].accent} data-mode={mode}>
                <span class="window"><span class="line"></span><span class="line short"></span></span>
              </span>
            {/each}
          </span>
          {theme.label}
        </button>
      {/each}
    </div>
    <p class="note">{prefs.theme === 'system' ? `following your system, which is ${prefs.resolved} right now` : `always ${prefs.theme}`}</p>
  </div>

  <div class="group">
    <div class="heading">
      <h3 id="colors-label">colours</h3>
      <div class="modes" role="radiogroup" aria-label="Mode to edit" tabindex="-1" onkeydown={(event) => arrows(event, ['light', 'dark'] as Mode[], editing, (mode) => (editing = mode))}>
        {#each ['light', 'dark'] as Mode[] as mode (mode)}
          <button role="radio" aria-checked={editing === mode} tabindex={editing === mode ? 0 : -1} onclick={() => (editing = mode)}>{mode}</button>
        {/each}
      </div>
    </div>

    <div class="seasons" aria-label="Seasons">
      {#each SEASONS as season (season.id)}
        <button
          class:on={palette.background === season[editing].background && palette.foreground === season[editing].foreground}
          style:--bg={season[editing].background}
          style:--ink={season[editing].foreground}
          style:--tint={season[editing].accent}
          title="madoromi {season.id}, {season.label}"
          onclick={() => prefs.season(season.id)}
        >
          <span class="kanji">{season.kanji}</span>{season.id}
        </button>
      {/each}
    </div>

    <div class="presets" aria-label="Accent presets">
      {#each ACCENTS as accent (accent.id)}
        <button class="preset" class:on={palette.accent === accent[editing]} style:--swatch={accent[editing]} title={accent.label} aria-label="accent {accent.label}" onclick={() => set({ accent: accent[editing] })}></button>
      {/each}
    </div>

    {#each fields as field (field.key)}
      <label class="color">
        <span>{field.label}</span>
        <span class="pick" style:--swatch={palette[field.key]}>
          <input type="color" value={palette[field.key]} oninput={(event) => set({ [field.key]: event.currentTarget.value })} aria-label="{field.label} colour" />
        </span>
        <input class="hex" value={palette[field.key]} spellcheck="false" maxlength="7" aria-label="{field.label} hex" oninput={(event) => typed(field.key, event.currentTarget.value)} onblur={(event) => (event.currentTarget.value = palette[field.key])} />
      </label>
    {/each}

    <label class="contrast">
      <span>contrast</span>
      <input type="range" min="0" max="100" value={palette.contrast} oninput={(event) => set({ contrast: Number(event.currentTarget.value) })} />
      <span class="value">{palette.contrast}</span>
    </label>

    <div class="actions">
      <button onclick={() => prefs.reset(editing)} disabled={JSON.stringify(palette) === JSON.stringify(DEFAULTS[editing])}>reset {editing}</button>
      <button onclick={copyTheme}>copy theme</button>
      <button onclick={pasteTheme}>paste theme</button>
    </div>
    {#if notice}<p class="note" role="status">{notice}</p>{/if}
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

  <p class="credit">
    colours from <a href="https://madoromi.moonwit.ch/" target="_blank" rel="noopener noreferrer">madoromi 微睡</a> by
    <a href="https://bsky.app/profile/personhood.removal.surgery" target="_blank" rel="noopener noreferrer">samhain</a>, inks of pilot iroshizuku
  </p>
</section>

<style>
  .pane {
    position: fixed;
    top: 50px;
    right: 10px;
    z-index: 50;
    display: grid;
    gap: 22px;
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
  h3 {
    margin: 0 0 8px;
    font-size: 13px;
    font-weight: 600;
  }
  .heading {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 10px;
  }
  .heading h3 {
    margin: 0;
  }
  .note {
    display: block;
    margin: 8px 0 0;
    color: var(--muted);
    font-size: 12px;
    line-height: 1.4;
  }
  button {
    color: var(--text);
    font: inherit;
    font-size: 12.5px;
    background: var(--field);
    border: 0;
    border-radius: 10px;
    cursor: pointer;
    transition: background-color 120ms ease, box-shadow 120ms ease, transform 100ms ease-out;
  }
  button:hover:not(:disabled) {
    background: var(--selected);
  }
  button:active:not(:disabled) {
    transform: scale(0.97);
  }
  button:disabled {
    color: var(--faint);
    cursor: default;
  }
  [aria-checked='true'] {
    box-shadow: 0 0 0 2px var(--accent);
  }
  .themes {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 6px;
  }
  .themes button {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 6px;
    padding: 8px 6px;
  }
  /* Small pictures of each theme, drawn in its own colours: a window on its ground. */
  .preview {
    display: flex;
    width: 100%;
    height: 38px;
    overflow: hidden;
    border-radius: 6px;
  }
  .half {
    flex: 1;
    padding: 8px 0 0 8px;
    background: var(--bg);
  }
  .half + .half {
    padding-left: 0;
  }
  .window {
    display: grid;
    align-content: start;
    gap: 4px;
    height: 100%;
    padding: 6px;
    background: color-mix(in oklab, var(--bg), #fff 78%);
    border-radius: 4px 0 0 0;
  }
  .half[data-mode='dark'] .window {
    background: color-mix(in oklab, var(--bg), var(--ink) 7%);
  }
  .half + .half .window {
    border-radius: 0;
  }
  .line {
    height: 3px;
    background: var(--ink);
    border-radius: 2px;
    opacity: 0.5;
  }
  .line.short {
    width: 55%;
    background: var(--tint);
    opacity: 1;
  }
  .modes {
    display: flex;
    gap: 2px;
    padding: 2px;
    background: var(--field);
    border-radius: 8px;
  }
  .modes button {
    height: 24px;
    padding: 0 10px;
    font-size: 12px;
    background: none;
    border-radius: 6px;
  }
  .modes [aria-checked='true'] {
    background: var(--surface);
    box-shadow: var(--shadow);
  }
  .seasons {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 6px;
    margin-bottom: 12px;
  }
  .seasons button {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 1px;
    height: 48px;
    padding: 0;
    color: var(--ink);
    font-size: 11.5px;
    background: var(--bg);
    box-shadow: inset 0 0 0 1px var(--hover);
  }
  .seasons button:hover:not(:disabled) {
    background: var(--bg);
  }
  .seasons button.on {
    box-shadow: 0 0 0 2px var(--accent);
  }
  .kanji {
    padding-top: 7px;
    color: var(--tint);
    font-family: var(--face);
    font-size: 15px;
    line-height: 1.2;
  }
  .credit {
    margin: -6px 0 0;
    color: var(--muted);
    font-size: 11.5px;
    line-height: 1.4;
  }
  .credit a {
    color: var(--accent);
    text-decoration: underline;
    text-decoration-color: color-mix(in oklab, var(--accent) 40%, transparent);
    text-underline-offset: 2px;
  }
  .presets {
    display: flex;
    gap: 8px;
    margin-bottom: 12px;
  }
  .preset {
    width: 22px;
    height: 22px;
    padding: 0;
    background: var(--swatch);
    border-radius: 50%;
  }
  .preset:hover:not(:disabled) {
    background: var(--swatch);
  }
  .preset.on {
    box-shadow: 0 0 0 2px var(--surface), 0 0 0 4px var(--swatch);
  }
  .color,
  .contrast {
    display: grid;
    grid-template-columns: 1fr auto 82px;
    align-items: center;
    gap: 8px;
    min-height: 34px;
    font-size: 12.5px;
  }
  .pick {
    position: relative;
    width: 24px;
    height: 24px;
    overflow: hidden;
    background: var(--swatch);
    border-radius: 7px;
    box-shadow: inset 0 0 0 1px var(--hover);
  }
  .pick input {
    position: absolute;
    inset: -8px;
    width: 40px;
    height: 40px;
    opacity: 0;
    cursor: pointer;
  }
  .pick:focus-within {
    box-shadow: 0 0 0 2px var(--focus-ring);
  }
  .hex {
    height: 28px;
    padding: 0 8px;
    color: var(--text);
    font-family: var(--mono);
    font-size: 12px;
    background: var(--field);
    border: 0;
    border-radius: 7px;
    outline: 0;
  }
  .hex:focus {
    box-shadow: 0 0 0 2px var(--focus-ring);
  }
  .contrast {
    grid-template-columns: auto 1fr 28px;
    margin-top: 4px;
  }
  .contrast input {
    width: 100%;
    accent-color: var(--accent);
  }
  .value {
    color: var(--muted);
    font-size: 12px;
    font-variant-numeric: tabular-nums;
    text-align: right;
  }
  .actions {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    margin-top: 12px;
  }
  .actions button {
    height: 28px;
    padding: 0 10px;
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
