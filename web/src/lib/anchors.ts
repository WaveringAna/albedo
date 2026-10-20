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

/** What a note dropped at a point on screen is about, or nothing for empty canvas. */
export function targetAt(x: number, y: number): Target | undefined {
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
      return { kind: 'lines', window, path: known.path, change: known.change, side, start: number, end: number, quote: quoteLines(known.diff, side, number, number) };
    }
  }

  const entry = hit.closest<HTMLElement>('[data-entry]');
  if (entry) return { kind: 'entry', window, entry: entry.dataset.entry!, quote: excerpt(entry.innerText) };
  return { kind: 'window', window };
}

/** The element a target points at now, when it is on screen. */
function anchorOf(target: Target): Element | null {
  const window = document.querySelector(`.svelte-flow__node[data-id="${CSS.escape(target.window)}"]`);
  if (!window || target.kind === 'window') return window;
  if (target.kind === 'entry') return window.querySelector(`[data-entry="${CSS.escape(target.entry)}"]`) ?? window;
  const host = window.querySelector(`[data-diff="${CSS.escape(diffKey(target.window, target.path, target.change))}"] diffs-container`);
  const rows = [...(host?.shadowRoot?.querySelectorAll<HTMLElement>(`[data-line="${target.end}"]`) ?? [])];
  const deletion = target.side === 'deletions';
  return rows.find((row) => (row.dataset.lineType?.includes('deletion') ?? false) === deletion) ?? rows[0] ?? host ?? window;
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
  if (target.kind === 'entry') return `on a message in ${title(target.window)}`;
  const name = target.path.split('/').pop();
  return `on ${name}:${target.start === target.end ? target.start : `${target.start}–${target.end}`}${target.side === 'deletions' ? ' (removed)' : ''}`;
}
