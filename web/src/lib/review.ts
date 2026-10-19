import { readHistory, type HistoryEntry } from './api';
import { hydrate } from './transcript.svelte';

// The changes one turn made, read from its history: every tool call's trace
// records each file it changed with the unified diff (robot-docs/web.md).

export interface Change {
  path: string;
  diff: string;
  added: number;
  removed: number;
  /** Why there is no diff (binary, unreadable, too large), when there is none. */
  reason?: string;
}

/** One file's changes in a turn, in the order they were made. */
export interface FileChanges {
  path: string;
  changes: Change[];
  added: number;
  removed: number;
}

/** The turn's entries: from its first position until the next turn begins. */
export async function readTurn(sessionId: string, turnId: string, from: number): Promise<HistoryEntry[]> {
  const turn: HistoryEntry[] = [];
  let after = from - 1;
  for (;;) {
    const page = await readHistory(sessionId, { after });
    for (const entry of page.items) {
      if (entry.position <= after) continue;
      if (entry.turn_id !== turnId) {
        if (turn.length) return turn;
        continue;
      }
      turn.push(entry);
    }
    if (!page.newer || !page.items.length) return turn;
    after = page.items.at(-1)!.position;
  }
}

/** Every change the turn's tool calls recorded, grouped by file. */
export async function turnChanges(entries: HistoryEntry[]): Promise<FileChanges[]> {
  const results = await Promise.all(entries.filter((entry) => entry.kind === 'tool_result').map(hydrate));
  const files = new Map<string, FileChanges>();
  for (const entry of results) {
    for (const part of entry.content) {
      if (part.kind !== 'trace') continue;
      const trace = part.trace as { changes?: { path: string; kind: string; diff?: string; added?: number; removed?: number; reason?: string }[] };
      for (const change of trace.changes ?? []) {
        const file = files.get(change.path) ?? { path: change.path, changes: [], added: 0, removed: 0 };
        file.changes.push({ path: change.path, diff: change.diff ?? '', added: change.added ?? 0, removed: change.removed ?? 0, reason: change.kind === 'diff' ? undefined : change.reason });
        file.added += change.added ?? 0;
        file.removed += change.removed ?? 0;
        files.set(change.path, file);
      }
    }
  }
  return [...files.values()];
}

export type DiffLine =
  | { kind: 'hunk'; text: string }
  | { kind: 'add' | 'remove' | 'context'; text: string; old: number | null; new: number | null };

/** A unified diff as rows with both line numbers, skipping its file headers. */
export function parseDiff(diff: string): DiffLine[] {
  const lines: DiffLine[] = [];
  let old = 0;
  let next = 0;
  for (const line of diff.split('\n')) {
    const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$/.exec(line);
    if (hunk) {
      old = Number(hunk[1]);
      next = Number(hunk[2]);
      lines.push({ kind: 'hunk', text: hunk[3].trim() });
    } else if (line.startsWith('---') || line.startsWith('+++') || line.startsWith('diff ') || line.startsWith('index ')) {
      continue;
    } else if (line.startsWith('+')) {
      lines.push({ kind: 'add', text: line.slice(1), old: null, new: next++ });
    } else if (line.startsWith('-')) {
      lines.push({ kind: 'remove', text: line.slice(1), old: old++, new: null });
    } else if (line.startsWith(' ') || (line === '' && lines.length)) {
      lines.push({ kind: 'context', text: line.slice(1), old: old++, new: next++ });
    }
  }
  // A diff's trailing newline leaves one empty context row.
  if (lines.at(-1)?.kind === 'context' && (lines.at(-1) as { text: string }).text === '') lines.pop();
  return lines;
}
