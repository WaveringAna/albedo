import { SvelteMap } from 'svelte/reactivity';
import { ApiError, getArtifact, sendMessage, uuidv7, type ArtifactDetail } from './api';

// Artifacts on the client: the details every window and chat row shares, the
// colours a page is given, and the window's side of the bridge a page talks
// to the chat through (robot-docs/artifacts.md).

/** What the client knows of each artifact, read once and again when a newer version is heard of. */
class Artifacts {
  #details = new SvelteMap<string, ArtifactDetail>();
  #problems = new SvelteMap<string, string>();
  #reading = new Map<string, Promise<void>>();

  get(id: string): ArtifactDetail | undefined {
    return this.#details.get(id);
  }

  /** Why an artifact cannot be shown, or undefined. */
  problem(id: string): string | undefined {
    return this.#problems.get(id);
  }

  /** Reads an artifact unless what is known already has `version`. */
  want(id: string, version = 0): Promise<void> {
    const known = this.#details.get(id);
    if (known && known.version >= version) return Promise.resolve();
    return this.read(id);
  }

  /** Reads an artifact again; one read at a time each. */
  read(id: string): Promise<void> {
    const reading = this.#reading.get(id);
    if (reading) return reading;
    const next = getArtifact(id)
      .then((detail) => {
        this.#details.set(id, detail);
        this.#problems.delete(id);
      })
      .catch((error) => {
        this.#problems.set(id, error instanceof ApiError && error.status === 404 ? 'this artifact was deleted' : String((error as Error).message ?? error));
      })
      .finally(() => this.#reading.delete(id));
    this.#reading.set(id, next);
    return next;
  }

  forget(id: string) {
    this.#details.delete(id);
    this.#problems.set(id, 'this artifact was deleted');
  }
}

export const artifacts = new Artifacts();

// What a page says of itself is checked before it is drawn or quoted.
function rect(value: any): PageRect | null {
  const fields = [value?.x, value?.y, value?.width, value?.height];
  if (!fields.every((field) => typeof field === 'number' && Number.isFinite(field))) return null;
  return { x: value.x, y: value.y, width: Math.max(0, value.width), height: Math.max(0, value.height) };
}

function pointed(value: any): Pointed | null {
  if (typeof value?.x !== 'number' || typeof value?.y !== 'number') return null;
  const part = rect(value.rect);
  if (typeof value.selector !== 'string' || !value.selector || value.selector.length > 1000 || typeof value.quote !== 'string' || !part)
    return { x: value.x, y: value.y, selector: null };
  return { x: value.x, y: value.y, selector: value.selector, quote: value.quote.slice(0, 601), rect: part };
}

// The client's palette, as the page's --albedo-* variables. The client's own
// values are expressions over its seed colours (color-mix, var()), which mean
// nothing inside the page, so each is resolved to a colour here first.
const COLOURS: Record<string, string> = {
  bg: 'var(--bg)',
  surface: 'var(--surface)',
  text: 'var(--text)',
  muted: 'var(--muted)',
  faint: 'var(--faint)',
  accent: 'var(--accent)',
  border: 'color-mix(in oklab, var(--text) 14%, var(--surface))',
  added: 'var(--added)',
  danger: 'var(--danger)',
};

export function themeVariables(): Record<string, string> {
  const probe = document.createElement('span');
  probe.style.display = 'none';
  document.body.append(probe);
  const variables: Record<string, string> = {};
  for (const [name, value] of Object.entries(COLOURS)) {
    probe.style.color = value;
    variables[`--albedo-${name}`] = getComputedStyle(probe).color;
  }
  probe.remove();
  const root = getComputedStyle(document.documentElement);
  variables['--albedo-sans'] = root.getPropertyValue('--sans').trim();
  variables['--albedo-mono'] = root.getPropertyValue('--mono').trim();
  return variables;
}

/** How many messages a page may send a minute without a click or key press behind each. */
export const UNPROMPTED_PER_MINUTE = 5;

type Request = { jsonrpc: '2.0'; id?: string | number; method?: string; params?: any };

/** A part of a page, in the page's own pixels. */
export type PageRect = { x: number; y: number; width: number; height: number };

/** What the page said is under a point of it: the part a note would be tied to. */
export type Pointed = { x: number; y: number; selector: string; quote: string; rect: PageRect } | { x: number; y: number; selector: null };

/** The bridge of each artifact window on the board, by window id, for notes tied into its page. */
export const pageHosts = new Map<string, PageHost>();

/**
 * The window's side of one page's bridge: JSON-RPC over postMessage, the
 * subset of MCP Apps a page here may use. A message sent right after the
 * person clicked or typed in the page goes to the chat at once; ones the page
 * sends by itself are held past a few a minute (the loop guard), until the
 * person sends or discards them.
 */
export class PageHost {
  /** Messages the loop guard is holding. */
  held = $state<string[]>([]);
  /** Failures the page reported since it loaded. */
  failures = $state<string[]>([]);
  /** The page's own height, as it last said. */
  height = $state<number | null>(null);
  /** What the page last said is under the pointer, while a note's tie is drawn over it. */
  pointed: Pointed | null = null;
  /** Where each part notes are tied to is now, as the page last said; null when it is gone. */
  rects = new Map<string, PageRect | null>();
  #watched: string[] = [];
  #unprompted: number[] = [];

  constructor(
    private readonly frame: () => HTMLIFrameElement | undefined,
    private readonly page: () => { title: string; version: number; session: string | null; theme: 'light' | 'dark' },
  ) {}

  /** Starts over for a page that loaded again. */
  reset() {
    this.failures = [];
    this.height = null;
    this.pointed = null;
    this.rects.clear();
  }

  /** The version of the page shown. */
  get version(): number {
    return this.page().version;
  }

  /** The page itself, on screen, and how much the canvas scales it. */
  frameBox(): { rect: DOMRect; scale: number } | null {
    const frame = this.frame();
    if (!frame?.isConnected) return null;
    const rect = frame.getBoundingClientRect();
    return { rect, scale: frame.clientWidth ? rect.width / frame.clientWidth : 1 };
  }

  /** Asks the page what is under a point of the screen; the answer lands in `pointed`. */
  point(x: number, y: number) {
    const box = this.frameBox();
    if (!box) return;
    this.notify('albedo/point', { x: (x - box.rect.left) / box.scale, y: (y - box.rect.top) / box.scale });
  }

  /** Has the page report where the part a selector names is, now and as it moves. */
  watch(selector: string) {
    if (this.#watched.includes(selector)) return;
    this.#watched = [...this.#watched, selector].slice(-64);
    this.notify('albedo/watch', { selectors: this.#watched });
  }

  /** Where a page rect is on screen. */
  onScreen(part: PageRect): DOMRect | null {
    const box = this.frameBox();
    if (!box) return null;
    const { rect, scale } = box;
    return new DOMRect(rect.left + part.x * scale, rect.top + part.y * scale, part.width * scale, part.height * scale);
  }

  receive(event: MessageEvent) {
    const frame = this.frame();
    if (!frame || event.source !== frame.contentWindow) return;
    const message = event.data as Request;
    if (!message || message.jsonrpc !== '2.0' || typeof message.method !== 'string') return;
    const { id, method, params } = message;
    switch (method) {
      case 'ui/initialize':
        return this.#answer(id, {
          protocolVersion: '2026-01-26',
          hostInfo: { name: 'albedo' },
          hostCapabilities: { message: {} },
          hostContext: { ...this.context(), displayMode: 'inline' },
        });
      case 'ui/notifications/initialized':
        // A page loaded again starts with nothing to watch.
        if (this.#watched.length) this.notify('albedo/watch', { selectors: this.#watched });
        return;
      case 'ui/message':
        return void this.#message(id, params);
      case 'ui/notifications/size-changed':
        if (typeof params?.height === 'number') this.height = params.height;
        return;
      case 'albedo/error':
        this.failures = [...this.failures.slice(-19), String(params?.message ?? 'something failed')];
        return;
      case 'albedo/wheel':
        return this.#wheel(params);
      case 'albedo/pointed':
        this.pointed = pointed(params);
        return;
      case 'albedo/rects':
        for (const [selector, part] of Object.entries(params?.rects ?? {})) {
          if (this.#watched.includes(selector)) this.rects.set(selector, rect(part));
        }
        return;
      default:
        // tools/call among them: a page cannot reach the agent's tools.
        if (id !== undefined) this.#fail(id, -32601, `${method} is not available to an artifact`);
    }
  }

  /** The theme and colours, for a page that has started or when they change. */
  context() {
    return { theme: this.page().theme, styles: { variables: themeVariables() } };
  }

  notify(method: string, params: unknown) {
    this.frame()?.contentWindow?.postMessage({ jsonrpc: '2.0', method, params }, '*');
  }

  /** Sends what the guard held, as though the person had asked for each. */
  async release() {
    const held = this.held;
    this.held = [];
    for (const text of held) await this.say(text);
  }

  /** Posts to the chat as the person, headed with the artifact it came from. */
  say(text: string) {
    const { title, version, session } = this.page();
    if (!session) return Promise.reject(new Error('the chat this artifact came from is gone'));
    return sendMessage(session, uuidv7(), `From the artifact “${title}” (v${version}):\n\n${text}`);
  }

  discard() {
    this.held = [];
  }

  async #message(id: string | number | undefined, params: any) {
    const text = Array.isArray(params?.content)
      ? params.content.filter((part: any) => part?.type === 'text' && typeof part.text === 'string').map((part: any) => part.text).join('\n')
      : '';
    if (!text.trim()) return this.#fail(id, -32602, 'a message needs text');
    if (!this.page().session) return this.#fail(id, -32002, 'the chat this artifact came from is gone');
    if (!params?.gesture) {
      const now = Date.now();
      this.#unprompted = this.#unprompted.filter((at) => now - at < 60_000);
      if (this.#unprompted.length >= UNPROMPTED_PER_MINUTE) {
        this.held = [...this.held, text];
        return this.#fail(id, -32001, 'held: this page sent several messages by itself, so albedo asks the person first');
      }
      this.#unprompted.push(now);
    }
    try {
      await this.say(text);
      this.#answer(id, {});
    } catch (error) {
      this.#fail(id, -32003, String((error as Error).message ?? error));
    }
  }

  // A pinch over the page zooms the canvas, as it does anywhere else: the
  // page passes it on, and it is replayed on the frame, where the canvas hears it.
  #wheel(params: any) {
    const frame = this.frame();
    if (!frame || typeof params?.deltaY !== 'number') return;
    const rect = frame.getBoundingClientRect();
    const scale = frame.clientWidth ? rect.width / frame.clientWidth : 1;
    frame.dispatchEvent(
      new WheelEvent('wheel', {
        deltaX: params.deltaX ?? 0,
        deltaY: params.deltaY,
        deltaMode: params.deltaMode ?? 0,
        ctrlKey: true,
        clientX: rect.left + (params.x ?? 0) * scale,
        clientY: rect.top + (params.y ?? 0) * scale,
        bubbles: true,
        cancelable: true,
      }),
    );
  }

  #answer(id: string | number | undefined, result: unknown) {
    if (id !== undefined) this.frame()?.contentWindow?.postMessage({ jsonrpc: '2.0', id, result }, '*');
  }

  #fail(id: string | number | undefined, code: number, message: string) {
    if (id !== undefined) this.frame()?.contentWindow?.postMessage({ jsonrpc: '2.0', id, error: { code, message } }, '*');
  }
}
