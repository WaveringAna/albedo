import type { Edge, Node, Viewport, useSvelteFlow } from '@xyflow/svelte';

// A board is an open canvas: windows sit anywhere, the view pans freely and
// zooms out to an overview. Svelte Flow draws, drags and sizes the windows;
// the board places new ones and owns the viewport.
//
// A window's data names what it shows and the window looks the live record
// up, so the saved board stays small and never holds stale daemon state.
//
// A view opened from a window names it as its parent; the canvas draws a
// faint line between them, so a board reads as conversations with the
// papers each one spread around it.
export type SessionWindow = Node<{ sessionId: string; parent?: string }, 'session'>;
/** The changes one turn made, walked file by file. `from` is the turn's first history position. */
/** `jump` asks the window to bring one file into view; `at` makes each ask new. */
export type ReviewWindow = Node<{ sessionId: string; turnId: string; from: number; parent?: string; jump?: { path: string; at: number } }, 'review'>;
export type Window = SessionWindow | ReviewWindow;

type Flow = ReturnType<typeof useSvelteFlow>;

export const SIZE = { width: 560, minWidth: 360, minHeight: 320 };
export const ZOOM = { min: 0.1, max: 1.5 };
const GAP = 32;

interface Saved {
  nodes: Window[];
  viewport: Viewport | null;
}

function load(key: string): Saved {
  try {
    const saved = JSON.parse(localStorage.getItem(key) ?? '');
    if (Array.isArray(saved?.nodes)) return { nodes: saved.nodes, viewport: saved.viewport?.zoom ? saved.viewport : null };
  } catch {}
  return { nodes: [], viewport: null };
}

/** One board's windows and view. Only the active board is on screen, so `flow` is set only while it is. */
export class Board {
  nodes = $state.raw<Window[]>([]);
  edges = $derived(
    this.nodes.flatMap((node): Edge[] =>
      node.data.parent && this.nodes.some((other) => other.id === node.data.parent)
        ? [{ id: `${node.data.parent}->${node.id}`, source: node.data.parent, target: node.id, type: 'default', selectable: false, focusable: false, class: 'tether' }]
        : [],
    ),
  );
  viewport = $state.raw<Viewport>({ x: 0, y: 0, zoom: 1 });
  flow: Flow | null = null;
  #key: string;
  #save: ReturnType<typeof setTimeout> | undefined;
  #whenShown: ((flow: Flow) => void) | null = null;
  #stop: () => void;

  constructor(id: string) {
    const key = (this.#key = `albedo.board.v2:${id}`);
    const saved = load(key);
    this.nodes = saved.nodes.map((node) => ({ ...node, height: node.height ?? 720, dragHandle: '.window-handle', selected: false }));
    this.viewport = saved.viewport ?? { x: 40, y: 72, zoom: 1 };
    this.#stop = $effect.root(() => {
      $effect(() => {
        const snapshot = { nodes: this.nodes.map(({ id, type, position, width, height, data }) => ({ id, type, position, width, height, data })), viewport: this.viewport };
        clearTimeout(this.#save);
        this.#save = setTimeout(() => localStorage.setItem(key, JSON.stringify(snapshot)), 250);
      });
    });
  }

  /** Drops the saved layout, for a deleted board. */
  forget() {
    clearTimeout(this.#save);
    this.#stop();
    localStorage.removeItem(this.#key);
  }

  /** The canvas calls this when the board comes on screen; anything asked of it while hidden runs then. */
  attach(flow: Flow) {
    this.flow = flow;
    const pending = this.#whenShown;
    this.#whenShown = null;
    if (pending) requestAnimationFrame(() => pending(flow));
  }

  detach() {
    this.flow = null;
  }

  /** Moves the view to a viewport now, without animation (wheel and pinch). */
  setView(viewport: Viewport) {
    const zoom = Math.min(ZOOM.max, Math.max(ZOOM.min, viewport.zoom));
    this.viewport = { ...viewport, zoom };
    this.flow?.setViewport(this.viewport);
  }

  /** Zooms by a factor around a point on screen, which stays under the pointer. */
  zoomAt(factor: number, point: { x: number; y: number }) {
    const { x, y, zoom } = this.viewport;
    const next = Math.min(ZOOM.max, Math.max(ZOOM.min, zoom * factor));
    const scale = next / zoom;
    this.setView({ x: point.x - (point.x - x) * scale, y: point.y - (point.y - y) * scale, zoom: next });
  }

  fit() {
    this.flow?.fitView({ padding: 0.12, maxZoom: 1, duration: 260 });
  }

  zoomTo(zoom: number) {
    const pane = paneRect();
    if (pane) this.zoomAt(zoom / this.viewport.zoom, { x: pane.width / 2, y: pane.height / 2 });
  }

  /** Brings a session's window into view, placing it beside the selected (or newest) window first. */
  openSession(sessionId: string) {
    this.#open({ id: `session:${sessionId}`, type: 'session', data: { sessionId } });
  }

  /** Opens the review of one turn's changes beside the window it was asked from. */
  openReview(sessionId: string, turnId: string, from: number, parent?: string, path?: string) {
    const id = `review:${sessionId}:${turnId}`;
    const jump = path ? { path, at: Date.now() } : undefined;
    this.#open({ id, type: 'review', data: { sessionId, turnId, from, parent, jump } }, 640);
    if (jump) this.nodes = this.nodes.map((node) => (node.id === id && node.type === 'review' ? { ...node, data: { ...node.data, jump } } : node));
  }

  #open(window: Pick<SessionWindow, 'id' | 'type' | 'data'> | Pick<ReviewWindow, 'id' | 'type' | 'data'>, width = SIZE.width) {
    if (!this.nodes.some((node) => node.id === window.id)) {
      const height = Math.round(Math.min(860, Math.max(480, (paneRect()?.height ?? 800) / this.viewport.zoom - 140)));
      const anchor = this.nodes.find((node) => node.id === window.data.parent);
      const placed = { ...window, position: this.#freeSpot(height, width, anchor), width, height, dragHandle: '.window-handle' } as Window;
      this.nodes = [...this.nodes, placed];
    }
    this.focus(window.id);
  }

  focus(id: string) {
    this.nodes = this.nodes.map((node) => ({ ...node, selected: node.id === id }));
    this.#withFlow(() => this.reveal(id));
  }

  remove(id: string) {
    this.nodes = this.nodes.filter((node) => node.id !== id);
  }

  /** Pans just enough to show a window whole, keeping the zoom the reader chose. */
  reveal(id: string) {
    const node = this.nodes.find((candidate) => candidate.id === id);
    const pane = paneRect();
    if (!node || !pane || !this.flow) return;
    const { x, y, zoom } = this.viewport;
    const margin = 24;
    const left = node.position.x * zoom + x;
    const top = node.position.y * zoom + y;
    const right = left + (node.width ?? SIZE.width) * zoom;
    const bottom = top + (node.height ?? 720) * zoom;
    let dx = 0;
    let dy = 0;
    if (right > pane.width - margin) dx = pane.width - margin - right;
    if (left + dx < margin) dx = margin - left;
    if (bottom > pane.height - margin) dy = pane.height - margin - bottom;
    if (top + dy < margin + 48) dy = margin + 48 - top;
    if (!dx && !dy) return;
    this.viewport = { x: x + dx, y: y + dy, zoom };
    this.flow.setViewport(this.viewport, { duration: 240 });
  }

  /** Selects the window nearest in a direction from the selected one and shows it. */
  step(by: 1 | -1) {
    const ordered = [...this.nodes].sort((a, b) => a.position.x - b.position.x || a.position.y - b.position.y);
    const index = ordered.findIndex((node) => node.selected);
    const next = ordered[index < 0 ? 0 : Math.min(ordered.length - 1, Math.max(0, index + by))];
    if (next) this.focus(next.id);
  }

  #withFlow(run: (flow: Flow) => void) {
    if (this.flow) run(this.flow);
    else this.#whenShown = run;
  }

  /**
   * The first window starts at the top left of the view. After that one goes
   * right of the selected window (or the newest), top-aligned, stepping right
   * past anything in the way, so windows never land on each other.
   */
  #freeSpot(height: number, width: number, near?: Window) {
    const anchor = near ?? this.nodes.find((node) => node.selected) ?? this.nodes.at(-1);
    if (!anchor) {
      const { x, y, zoom } = this.viewport;
      return { x: Math.round((48 - x) / zoom), y: Math.round((88 - y) / zoom) };
    }
    const spot = { x: anchor.position.x + (anchor.width ?? SIZE.width) + GAP, y: anchor.position.y };
    let blocker: Window | undefined;
    while ((blocker = this.nodes.find((node) => overlaps(node, spot, width, height)))) spot.x = blocker.position.x + (blocker.width ?? SIZE.width) + GAP;
    return spot;
  }
}

function paneRect() {
  return document.querySelector('.svelte-flow')?.getBoundingClientRect() ?? null;
}

function overlaps(node: Window, spot: { x: number; y: number }, width: number, height: number) {
  const wide = node.width ?? SIZE.width;
  const tall = node.height ?? 720;
  return spot.x < node.position.x + wide + GAP && spot.x + width + GAP > node.position.x && spot.y < node.position.y + tall && spot.y + height > node.position.y;
}
