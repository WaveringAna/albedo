import type { Target } from './board.svelte';
import { parseDiff } from './review';

// Where a note's target is on screen, and what is under a point when a note
// is dropped. Targets are found in the DOM by what they show, so a tie
// survives the window redrawing: a window by its node id, a chat message or
// step by `data-entry`, diff lines by the diff's `data-diff` key and the
// line's number inside Pierre's shadow root.

/** Diffs on screen by key, so a dropped note can quote the lines it lands on. */
export const diffs = new Map<string, { path: string; change: number; diff: string }>();

export function diffKey(window: string, path: string, change: number) {
  return `${window}#${path}#${change}`;
}

function windowOf(element: Element | null): string | null {
  const node = element?.closest<HTMLElement>('.svelte-flow__node');
  return node && !node.classList.contains('svelte-flow__node-note') ? (node.dataset.id ?? null) : null;
}

const QUOTE_CHARS = 600;

function excerpt(text: string) {
  const trimmed = text.replace(/\s+\n/g, '\n').trim();
  return trimmed.length > QUOTE_CHARS ? `${trimmed.slice(0, QUOTE_CHARS)}…` : trimmed;
}

/** The lines of a diff a note covers, as diff text with their signs. */
export function quoteLines(diff: string, side: 'additions' | 'deletions', start: number, end: number): string {
  return parseDiff(diff)
    .flatMap((line) => {
      if (line.kind === 'hunk') return [];
      const number = side === 'additions' ? line.new : line.old;
      if (number === null || number < start || number > end) return [];
      return [(line.kind === 'add' ? '+' : line.kind === 'remove' ? '-' : ' ') + line.text];
    })
    .join('\n');
}

/** What a note dropped at a point on screen would be about, and the element that shows it. */
export function pick(x: number, y: number): { target: Target; element: Element } | undefined {
  const hit = document.elementsFromPoint(x, y).find((element) => !element.closest('.svelte-flow__node-note'));
  if (!hit) return undefined;
  const window = windowOf(hit);
  if (!window) return undefined;

  if (hit.tagName.toLowerCase() === 'diffs-container' && hit.shadowRoot) {
    const row = (hit.shadowRoot.elementsFromPoint(x, y) as Element[]).map((element) => element.closest<HTMLElement>('[data-line]')).find(Boolean);
    const known = diffs.get(hit.closest<HTMLElement>('[data-diff]')?.dataset.diff ?? '');
    if (row && known) {
      const number = Number(row.dataset.line);
      const side = row.dataset.lineType?.includes('deletion') ? 'deletions' : 'additions';
      return { target: { kind: 'lines', window, path: known.path, change: known.change, side, start: number, end: number, quote: quoteLines(known.diff, side, number, number) }, element: row };
    }
  }

  const entry = hit.closest<HTMLElement>('[data-entry]');
  if (entry) {
    const step = entry.classList.contains('tool') || entry.classList.contains('thought');
    return { target: { kind: 'entry', window, entry: entry.dataset.entry!, step, quote: excerpt(entry.innerText) }, element: entry };
  }
  return { target: { kind: 'window', window }, element: hit.closest('.svelte-flow__node')! };
}

export function targetAt(x: number, y: number): Target | undefined {
  return pick(x, y)?.target;
}

/** The element a target points at now, when it is on screen. */
export function anchorOf(target: Target): Element | null {
  const window = document.querySelector(`.svelte-flow__node[data-id="${CSS.escape(target.window)}"]`);
  if (!window || target.kind === 'window') return window;
  if (target.kind === 'entry') return window.querySelector(`[data-entry="${CSS.escape(target.entry)}"]`) ?? window;
  const host = window.querySelector(`[data-diff="${CSS.escape(diffKey(target.window, target.path, target.change))}"] diffs-container`);
  const rows = [...(host?.shadowRoot?.querySelectorAll<HTMLElement>(`[data-line="${target.end}"]`) ?? [])];
  const deletion = target.side === 'deletions';
  return rows.find((row) => (row.dataset.lineType?.includes('deletion') ?? false) === deletion) ?? rows[0] ?? host ?? window;
}

/**
 * Where a target sits on screen, held inside the window and whatever scrolls
 * it, or nothing while it is scrolled out of sight or is the whole window.
 */
export function targetBox(target: Target): DOMRect | null {
  if (target.kind === 'window') return null;
  const first = anchorOf(target);
  if (!first) return null;
  let rect = first.getBoundingClientRect();
  if (target.kind === 'lines' && target.start !== target.end) {
    const top = anchorOf({ ...target, end: target.start })?.getBoundingClientRect();
    if (top) rect = new DOMRect(rect.left, Math.min(top.top, rect.top), rect.width, Math.max(top.bottom, rect.bottom) - Math.min(top.top, rect.top));
  }
  const root = first.getRootNode();
  const light = root instanceof ShadowRoot ? root.host : first;
  const frame = (light.closest('.nowheel') ?? light.closest('.svelte-flow__node'))?.getBoundingClientRect();
  if (!frame) return rect;
  const top = Math.max(rect.top, frame.top);
  const bottom = Math.min(rect.bottom, frame.bottom);
  if (bottom <= top) return null;
  const left = Math.max(rect.left, frame.left);
  return new DOMRect(left, top, Math.min(rect.right, frame.right) - left, bottom - top);
}

/**
 * The point on screen a tie should end at: the target's left or right edge,
 * whichever faces the note, held inside the window and whatever scrolls it.
 */
export function anchorPoint(target: Target, from: { x: number; y: number }): { x: number; y: number } | null {
  const anchor = anchorOf(target);
  if (!anchor) return null;
  const root = anchor.getRootNode();
  const light = root instanceof ShadowRoot ? root.host : anchor;
  const node = light.closest('.svelte-flow__node')?.getBoundingClientRect();
  const frame = (light.closest('.nowheel') ?? light.closest('.svelte-flow__node'))?.getBoundingClientRect();
  const rect = anchor.getBoundingClientRect();
  let y = target.kind === 'window' ? rect.top + 22 : rect.top + Math.min(rect.height / 2, 12);
  if (frame) y = Math.min(frame.bottom - 6, Math.max(frame.top + 6, y));
  const box = node ?? rect;
  const x = from.x > box.left + box.width / 2 ? box.right : box.left;
  return { x, y };
}

/** How a note names its target, short. */
export function describe(target: Target | undefined, title: (window: string) => string): string {
  if (!target) return 'a loose note';
  if (target.kind === 'window') return `on ${title(target.window)}`;
  if (target.kind === 'entry') return `on ${target.step ? 'a step' : 'a message'} in ${title(target.window)}`;
  const name = target.path.split('/').pop();
  return `on ${name}:${target.start === target.end ? target.start : `${target.start}–${target.end}`}${target.side === 'deletions' ? ' (removed)' : ''}`;
}
