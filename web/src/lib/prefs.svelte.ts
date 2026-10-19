// Client preferences, kept in this browser. The theme follows the system
// unless chosen; index.html applies the saved choice before the first paint,
// and this keeps <html> in step afterwards.

export type Theme = 'system' | 'light' | 'dark';
export type Accent = 'pine' | 'lake' | 'clay' | 'graphite';

export const ACCENTS: { id: Accent; label: string }[] = [
  { id: 'pine', label: 'Pine' },
  { id: 'lake', label: 'Lake' },
  { id: 'clay', label: 'Clay' },
  { id: 'graphite', label: 'Graphite' },
];

const STORAGE_KEY = 'albedo.prefs.v1';

interface Saved {
  theme: Theme;
  accent: Accent;
  dots: boolean;
}

function load(): Saved {
  const fallback: Saved = { theme: 'system', accent: 'pine', dots: true };
  try {
    return { ...fallback, ...JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '{}') };
  } catch {
    return fallback;
  }
}

class Prefs {
  #saved = load();
  theme = $state<Theme>(this.#saved.theme);
  accent = $state<Accent>(this.#saved.accent);
  dots = $state(this.#saved.dots);
  #systemDark = $state(matchMedia('(prefers-color-scheme: dark)').matches);
  resolved = $derived<'light' | 'dark'>(this.theme === 'system' ? (this.#systemDark ? 'dark' : 'light') : this.theme);

  constructor() {
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (event) => (this.#systemDark = event.matches));
    $effect.root(() => {
      $effect(() => {
        const root = document.documentElement;
        root.dataset.theme = this.resolved;
        root.dataset.accent = this.accent;
        localStorage.setItem(STORAGE_KEY, JSON.stringify({ theme: this.theme, accent: this.accent, dots: this.dots }));
      });
    });
  }
}

export const prefs = new Prefs();
