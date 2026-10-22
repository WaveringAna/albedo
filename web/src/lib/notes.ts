import { sendMessage, uuidv7 } from './api';
import { artifacts } from './artifacts.svelte';
import type { Board, NoteWindow } from './board.svelte';

// Sending notes: each says what it was tied to, then what was written. Notes
// for one session go as one message; a note tied to a chat window itself is
// just a message, written somewhere roomier, and one tied to an artifact says
// which artifact and version it is about.

function part(board: Board, note: NoteWindow): string {
  const { target, text } = note.data;
  if (target?.kind === 'window') {
    const window = board.nodes.find((node) => node.id === target.window);
    if (window?.type !== 'artifact') return text.trim();
    const shown = artifacts.get(window.data.artifact);
    const version = window.data.version ?? shown?.version;
    return `On the artifact “${shown?.title ?? window.data.artifact}”${version ? ` (v${version})` : ''}:\n\n${text.trim()}`;
  }
  if (!target) return text.trim();
  if (target.kind === 'entry') return `On this:\n${target.quote.split('\n').map((line) => `> ${line}`).join('\n')}\n\n${text.trim()}`;
  const lines = target.start === target.end ? `${target.start}` : `${target.start}-${target.end}`;
  return `${target.path}:${lines}${target.side === 'deletions' ? ' (removed lines)' : ''}\n\`\`\`diff\n${target.quote}\n\`\`\`\n${text.trim()}`;
}

/** Whether a note can be sent: it has words and is tied into some session. */
export function sendable(board: Board, note: NoteWindow): boolean {
  return !!note.data.text.trim() && !!note.data.target && !!board.sessionOf(note.data.target.window);
}

/** Sends notes, one message per session, with an optional opening line; marks them sent. */
export async function sendNotes(board: Board, notes: NoteWindow[], lead = ''): Promise<void> {
  const bySession = new Map<string, NoteWindow[]>();
  for (const note of notes.filter((candidate) => sendable(board, candidate))) {
    const session = board.sessionOf(note.data.target!.window)!;
    bySession.set(session, [...(bySession.get(session) ?? []), note]);
  }
  for (const [session, group] of bySession) {
    const text = [lead.trim(), ...group.map((note) => part(board, note))].filter(Boolean).join('\n\n');
    await sendMessage(session, uuidv7(), text);
    for (const note of group) board.updateNote(note.id, { sent: true });
  }
}
