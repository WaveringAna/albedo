// Client preferences, kept in this browser. The theme follows the system
// unless chosen; index.html applies the saved choice before the first paint,
// and this keeps <html> in step afterwards.

export type Theme = 'system' | 'light' | 'dark';
export type Accent = 'albedo' | 'pine' | 'lake' | 'clay' | 'graphite';

export const ACCENTS: { id: Accent; label: string }[] = [
  { id: 'albedo', label: 'albedo' },
  { id: 'pine', label: 'pine' },
  { id: 'lake', label: 'lake' },
  { id: 'clay', label: 'clay' },
  { id: 'graphite', label: 'graphite' },
];

// v1 defaulted the accent to pine; v2 keeps its theme and dots but starts
// everyone on albedo's own mauve.
const STORAGE_KEY = 'albedo.prefs.v2';
const EARLIER_KEY = 'albedo.prefs.v1';

interface Saved {
  theme: Theme;
  accent: Accent;
  dots: boolean;
}

function load(): Saved {
  const fallback: Saved = { theme: 'system', accent: 'albedo', dots: true };
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved) return { ...fallback, ...JSON.parse(saved) };
    const { theme, dots } = JSON.parse(localStorage.getItem(EARLIER_KEY) ?? '{}');
    localStorage.removeItem(EARLIER_KEY);
    return { ...fallback, ...(theme ? { theme } : {}), ...(typeof dots === 'boolean' ? { dots } : {}) };
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
