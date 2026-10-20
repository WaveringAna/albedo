// Client preferences, kept in this browser. The theme follows the system
// unless chosen. Each mode has its own three colours and a contrast, from
// which app.css derives every other token; index.html applies the saved
// choice before the first paint, and this keeps <html> in step afterwards.

export type Theme = 'system' | 'light' | 'dark';
export type Mode = 'light' | 'dark';

export interface Palette {
  accent: string;
  background: string;
  foreground: string;
  /** 0 to 100: how far surfaces and secondary text step from the ground. */
  contrast: number;
}

// The colours are madoromi's (https://madoromi.moonwit.ch/, MPL-2.0, by
// samhain): Pilot iroshizuku inks on paper. Each season is a ground (kami),
// an ink (sumi) and wisteria (fuji) for its accent, by day and by night.
export const SEASONS: { id: string; kanji: string; label: string; light: Omit<Palette, 'contrast'>; dark: Omit<Palette, 'contrast'> }[] = [
  { id: 'haru', kanji: '春', label: 'spring', light: { accent: '#6928bd', background: '#f6eff8', foreground: '#584a5c' }, dark: { accent: '#ddb3ff', background: '#241c26', foreground: '#e1d1e7' } },
  { id: 'natsu', kanji: '夏', label: 'summer', light: { accent: '#6526b9', background: '#e9f4f8', foreground: '#3b545e' }, dark: { accent: '#aea8ff', background: '#132227', foreground: '#c0dde8' } },
  { id: 'aki', kanji: '秋', label: 'autumn', light: { accent: '#581ca7', background: '#f8f0e9', foreground: '#5d4c3c' }, dark: { accent: '#d3a1ff', background: '#271d14', foreground: '#e8d3c1' } },
  { id: 'fuyu', kanji: '冬', label: 'winter', light: { accent: '#5e21b0', background: '#f0f1f8', foreground: '#4a4e63' }, dark: { accent: '#bbb8ff', background: '#1c1e2a', foreground: '#d2d6eb' } },
];

export const DEFAULTS: Record<Mode, Palette> = {
  light: { ...SEASONS[0].light, contrast: 45 },
  dark: { ...SEASONS[0].dark, contrast: 50 },
};

/** Quick picks for the accent: madoromi's spring inks, by day and by night. */
export const ACCENTS: { id: string; label: string; light: string; dark: string }[] = [
  { id: 'fuji', label: 'fuji 藤', light: '#6928bd', dark: '#ddb3ff' },
  { id: 'sakura', label: 'sakura 桜', light: '#aa6e89', dark: '#ffc5da' },
  { id: 'botan', label: 'botan 牡丹', light: '#b25d9d', dark: '#fe8dc0' },
  { id: 'sora', label: 'sora 空', light: '#008bae', dark: '#88d9eb' },
  { id: 'tokiwa', label: 'tokiwa 常磐', light: '#009162', dark: '#7bd6b6' },
  { id: 'kaki', label: 'kaki 柿', light: '#fd5217', dark: '#ffbb74' },
];

const STORAGE_KEY = 'albedo.prefs.v4';
// Also kept in a cookie, which is shared by every port on this host, so the
// dev server and `albedo web` (and each new port it picks) open with the same
// look. The cookie wins when both exist; `albedo web` never forwards it.
const COOKIE = 'albedo_prefs';
const EARLIER_KEYS = ['albedo.prefs.v3', 'albedo.prefs.v2', 'albedo.prefs.v1'];
const HEX = /^#[0-9a-f]{6}$/i;

/** Font families as typed, or empty for the default stack. */
export interface Fonts {
  ui: string;
  code: string;
}

interface Saved {
  theme: Theme;
  dots: boolean;
  /** Whether a narrow screen gets the canvas rather than one chat at a time. */
  canvasOnPhone: boolean;
  /** Whether the sessions sit on the right, and search and settings on the left. */
  sidebarRight: boolean;
  palettes: Record<Mode, Palette>;
  fonts: Fonts;
}

const GENERIC = new Set(['serif', 'sans-serif', 'monospace', 'cursive', 'fantasy', 'system-ui', 'ui-serif', 'ui-sans-serif', 'ui-monospace', 'ui-rounded', 'math', 'emoji']);

/** A typed family list as CSS: each name quoted unless it is a generic family; nothing that could end the value. */
export function fontStack(typed: string, fallback: string): string | null {
  const names = typed
    .replace(/[;{}<>\\]/g, '')
    .slice(0, 200)
    .split(',')
    .map((name) => name.trim().replace(/^["']|["']$/g, ''))
    .filter(Boolean);
  if (!names.length) return null;
  return [...names.map((name) => (GENERIC.has(name.toLowerCase()) ? name : `"${name.replace(/"/g, '')}"`)), fallback].join(', ');
}

export const FONT_FALLBACK = { ui: "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif", code: "ui-monospace, 'SF Mono', Menlo, Consolas, monospace" };

function readFonts(value: unknown): Fonts {
  const given = (value && typeof value === 'object' ? value : {}) as Partial<Fonts>;
  const text = (key: keyof Fonts) => (typeof given[key] === 'string' ? given[key].slice(0, 200) : '');
  return { ui: text('ui'), code: text('code') };
}

function readCookie(): unknown {
  const found = document.cookie.split('; ').find((part) => part.startsWith(`${COOKIE}=`));
  return found ? JSON.parse(decodeURIComponent(found.slice(COOKIE.length + 1))) : null;
}

/** A palette from untrusted JSON: known fields with valid values, the rest from the defaults. */
export function readPalette(value: unknown, mode: Mode): Palette {
  const given = (value && typeof value === 'object' ? value : {}) as Partial<Palette>;
  const color = (key: 'accent' | 'background' | 'foreground') => (typeof given[key] === 'string' && HEX.test(given[key]) ? given[key].toLowerCase() : DEFAULTS[mode][key]);
  const contrast = typeof given.contrast === 'number' && given.contrast >= 0 && given.contrast <= 100 ? Math.round(given.contrast) : DEFAULTS[mode].contrast;
  return { accent: color('accent'), background: color('background'), foreground: color('foreground'), contrast };
}

function load(): Saved {
  const fallback: Saved = { theme: 'system', dots: true, canvasOnPhone: false, sidebarRight: false, palettes: { ...DEFAULTS }, fonts: { ui: '', code: '' } };
  try {
    const saved = (readCookie() ?? JSON.parse(localStorage.getItem(STORAGE_KEY) ?? 'null')) as Record<string, any> | null;
    if (saved) {
      return {
        theme: ['system', 'light', 'dark'].includes(saved.theme) ? saved.theme : 'system',
        dots: saved.dots !== false,
        canvasOnPhone: saved.canvasOnPhone === true,
        sidebarRight: saved.sidebarRight === true,
        palettes: { light: readPalette(saved.palettes?.light, 'light'), dark: readPalette(saved.palettes?.dark, 'dark') },
        fonts: readFonts(saved.fonts),
      };
    }
    // Earlier versions' theme and dots carry over; their colours give way to madoromi.
    for (const key of EARLIER_KEYS) {
      const earlier = JSON.parse(localStorage.getItem(key) ?? 'null');
      localStorage.removeItem(key);
      if (earlier) return { ...fallback, theme: earlier.theme ?? 'system', dots: earlier.dots !== false };
    }
  } catch {}
  return fallback;
}

/** The custom properties app.css derives the theme from. */
export function seedVariables(palette: Palette): Record<string, string> {
  return {
    '--seed-accent': palette.accent,
    '--seed-bg': palette.background,
    '--seed-fg': palette.foreground,
    '--contrast': String(palette.contrast / 100),
  };
}

class Prefs {
  #saved = load();
  theme = $state<Theme>(this.#saved.theme);
  dots = $state(this.#saved.dots);
  canvasOnPhone = $state(this.#saved.canvasOnPhone);
  sidebarRight = $state(this.#saved.sidebarRight);
  palettes = $state<Record<Mode, Palette>>(this.#saved.palettes);
  fonts = $state<Fonts>(this.#saved.fonts);
  #systemDark = $state(matchMedia('(prefers-color-scheme: dark)').matches);
  resolved = $derived<Mode>(this.theme === 'system' ? (this.#systemDark ? 'dark' : 'light') : this.theme);

  constructor() {
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (event) => (this.#systemDark = event.matches));
    $effect.root(() => {
      $effect(() => {
        const root = document.documentElement;
        root.dataset.theme = this.resolved;
        root.dataset.sidebar = this.sidebarRight ? 'right' : 'left';
        for (const [name, value] of Object.entries(seedVariables(this.palettes[this.resolved]))) root.style.setProperty(name, value);
        for (const [name, typed, fallback] of [['--sans', this.fonts.ui, FONT_FALLBACK.ui], ['--mono', this.fonts.code, FONT_FALLBACK.code]] as const) {
          const stack = fontStack(typed, fallback);
          if (stack) root.style.setProperty(name, stack);
          else root.style.removeProperty(name);
        }
        const saved = JSON.stringify({ theme: this.theme, dots: this.dots, canvasOnPhone: this.canvasOnPhone, sidebarRight: this.sidebarRight, palettes: this.palettes, fonts: this.fonts });
        localStorage.setItem(STORAGE_KEY, saved);
        document.cookie = `${COOKIE}=${encodeURIComponent(saved)}; path=/; max-age=31536000; samesite=strict`;
      });
    });
  }

  reset(mode: Mode) {
    this.palettes[mode] = { ...DEFAULTS[mode] };
  }

  /** A season sets both modes' colours and keeps each mode's contrast. */
  season(id: string) {
    const season = SEASONS.find((candidate) => candidate.id === id);
    if (!season) return;
    this.palettes = { light: { ...season.light, contrast: this.palettes.light.contrast }, dark: { ...season.dark, contrast: this.palettes.dark.contrast } };
  }
}

export const prefs = new Prefs();
