import { uuidv7, type Session } from './api';
import { Board } from './board.svelte';
import { layout } from './layout.svelte';

// A board is a named canvas of panels: sessions from any folders, arranged
// however the reader likes. Open boards are the tabs; closing a tab keeps the
// board (and where its panels sit) until it is deleted.
// "Workspace" stays what albedo already means by it: a session's folder.

const STORAGE_KEY = 'albedo.boards.v1';

interface Entry {
  id: string;
  name: string;
  open: boolean;
}

function load(): { entries: Entry[]; active: string | null } {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '');
    if (Array.isArray(saved?.entries)) return { entries: saved.entries, active: saved.active ?? null };
  } catch {}
  return { entries: [], active: null };
}

function forgetEarlierLayouts() {
  localStorage.removeItem('albedo.board.v1');
  localStorage.removeItem('albedo.tabs.v1');
  for (const key of Object.keys(localStorage)) if (key.startsWith('albedo.board.v1:/')) localStorage.removeItem(key);
}

class Boards {
  #boards = new Map<string, Board>();
  entries = $state.raw<Entry[]>([]);
  active = $state<string | null>(null);
  /** The tab whose name is being edited. */
  renaming = $state<string | null>(null);
  tabs = $derived(this.entries.filter((entry) => entry.open));
  closed = $derived(this.entries.filter((entry) => !entry.open));
  board = $derived(this.active ? (this.#boards.get(this.active) ?? null) : null);

  constructor() {
    forgetEarlierLayouts();
    const saved = load();
    for (const entry of saved.entries) this.#get(entry.id);
    this.entries = saved.entries;
    this.active = this.tabs.some((tab) => tab.id === saved.active) ? saved.active : (this.tabs[0]?.id ?? null);
    if (!this.active) this.create();
    $effect.root(() => {
      $effect(() => localStorage.setItem(STORAGE_KEY, JSON.stringify({ entries: this.entries, active: this.active })));
    });
  }

  #get(id: string) {
    let board = this.#boards.get(id);
    if (!board) this.#boards.set(id, (board = new Board(id)));
    return board;
  }

  nameOf(id: string) {
    return this.entries.find((entry) => entry.id === id)?.name ?? '';
  }

  create() {
    const taken = new Set(this.entries.map((entry) => entry.name));
    let number = this.entries.length + 1;
    while (taken.has(`board ${number}`)) number++;
    const entry = { id: uuidv7(), name: `board ${number}`, open: true };
    this.#get(entry.id);
    this.entries = [...this.entries, entry];
    this.active = entry.id;
  }

  show(id: string) {
    this.entries = this.entries.map((entry) => (entry.id === id ? { ...entry, open: true } : entry));
    this.active = id;
  }

  rename(id: string, name: string) {
    const trimmed = name.trim();
    if (trimmed) this.entries = this.entries.map((entry) => (entry.id === id ? { ...entry, name: trimmed } : entry));
  }

  /** Hides the tab; the board stays and can be reopened. The last tab never closes, so there is always a canvas. */
  close(id: string) {
    if (this.tabs.length < 2) return;
    this.#leave(id);
    this.entries = this.entries.map((entry) => (entry.id === id ? { ...entry, open: false } : entry));
  }

  delete(id: string) {
    this.#leave(id);
    this.entries = this.entries.filter((entry) => entry.id !== id);
    this.#get(id).forget();
    this.#boards.delete(id);
    if (!this.active) this.create();
  }

  #leave(id: string) {
    if (this.active !== id) return;
    const index = this.tabs.findIndex((tab) => tab.id === id);
    const others = this.tabs.filter((tab) => tab.id !== id);
    this.active = others[Math.min(index, others.length - 1)]?.id ?? null;
  }

  /** Steps to the neighbouring tab, wrapping at either end. */
  step(by: 1 | -1) {
    const index = this.tabs.findIndex((tab) => tab.id === this.active);
    if (index < 0 || this.tabs.length < 2) return;
    this.active = this.tabs[(index + by + this.tabs.length) % this.tabs.length].id;
  }

  /** Moves a tab to sit where another tab is now. */
  move(id: string, onto: string) {
    const moving = this.entries.find((entry) => entry.id === id);
    if (!moving || id === onto) return;
    const rest = this.entries.filter((entry) => entry.id !== id);
    const at = rest.findIndex((entry) => entry.id === onto);
    const after = this.entries.findIndex((entry) => entry.id === id) < this.entries.findIndex((entry) => entry.id === onto);
    rest.splice(at + (after ? 1 : 0), 0, moving);
    this.entries = rest;
  }

  /** Opens a session: a window on the canvas, or the whole screen on a phone. */
  openSession(session: Session) {
    if (layout.phone) layout.open(session.id);
    else this.board?.openSession(session.id);
  }
}

export const boards = new Boards();
