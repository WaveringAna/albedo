import type { DiffLineAnnotation, SelectedLineRange } from '@pierre/diffs';
import { sendMessage, uuidv7 } from './api';
import { parseDiff, type FileChanges } from './review';

// A review's comments, kept while its window is open. Each sits under the
// lines it is about in one of the turn's diffs; sending gathers them into
// one message, the way a code review goes back to its author.

export interface Comment {
  id: string;
  path: string;
  /** Which of the file's diffs in the turn, in order. */
  change: number;
  side: 'additions' | 'deletions';
  start: number;
  end: number;
  text: string;
  /** Still being written; not part of the review until added. */
  draft: boolean;
  /** What the open field holds, kept here so it survives the card redrawing. */
  typed: string;
}

/** What a diff's anchor carries: the comment it stands for. */
export type Note = { id: string };

export class Review {
  comments = $state<Comment[]>([]);
  summary = $state('');
  sending = $state(false);
  sent = $state(false);
  error = $state<string | null>(null);

  constructor(
    readonly sessionId: string,
    readonly files: () => FileChanges[],
  ) {}

  added = $derived(this.comments.filter((comment) => !comment.draft));

  /** The notes one diff carries, for the renderer. */
  notesFor(path: string, change: number): DiffLineAnnotation<Note>[] {
    return this.comments
      .filter((comment) => comment.path === path && comment.change === change)
      .map((comment) => ({ side: comment.side, lineNumber: comment.end, metadata: { id: comment.id } }));
  }

  start(path: string, change: number, range: SelectedLineRange) {
    const side = range.endSide ?? range.side ?? 'additions';
    const [start, end] = range.start <= range.end ? [range.start, range.end] : [range.end, range.start];
    // A draft someone typed into stays open; only empty ones give way.
    const kept = this.comments.filter((comment) => !(comment.draft && !comment.typed.trim() && !comment.text));
    this.comments = [...kept, { id: uuidv7(), path, change, side, start, end, text: '', draft: true, typed: '' }];
  }

  type(id: string, typed: string) {
    this.comments = this.comments.map((comment) => (comment.id === id ? { ...comment, typed } : comment));
  }

  save(id: string, text: string) {
    if (!text.trim()) return this.remove(id);
    this.comments = this.comments.map((comment) => (comment.id === id ? { ...comment, text: text.trim(), draft: false } : comment));
  }

  edit(id: string) {
    this.comments = this.comments.map((comment) => (comment.id === id ? { ...comment, draft: true, typed: comment.text } : comment));
  }

  remove(id: string) {
    this.comments = this.comments.filter((comment) => comment.id !== id);
  }

  /** The review as one message: each comment with the lines it is about. */
  message(): string {
    const parts = ['Review of your changes:'];
    if (this.summary.trim()) parts.push(this.summary.trim());
    const files = this.files();
    for (const comment of this.added) {
      const diff = files.find((file) => file.path === comment.path)?.changes[comment.change]?.diff ?? '';
      const lines = parseDiff(diff).filter(
        (line) => line.kind !== 'hunk' && (comment.side === 'additions' ? line.new : line.old) !== null && within(comment, comment.side === 'additions' ? line.new! : line.old!),
      ) as { kind: 'add' | 'remove' | 'context'; text: string }[];
      const where = `${comment.path}:${comment.start === comment.end ? comment.start : `${comment.start}-${comment.end}`}${comment.side === 'deletions' ? ' (removed lines)' : ''}`;
      const quoted = lines.map((line) => (line.kind === 'add' ? '+' : line.kind === 'remove' ? '-' : ' ') + line.text).join('\n');
      parts.push(`${where}\n\`\`\`diff\n${quoted}\n\`\`\`\n${comment.text}`);
    }
    return parts.join('\n\n');
  }

  async send() {
    if (!this.added.length && !this.summary.trim()) return;
    this.sending = true;
    this.error = null;
    try {
      await sendMessage(this.sessionId, uuidv7(), this.message());
      this.comments = this.comments.filter((comment) => comment.draft);
      this.summary = '';
      this.sent = true;
    } catch (error) {
      this.error = String((error as Error).message ?? error);
    } finally {
      this.sending = false;
    }
  }
}

function within(comment: Comment, line: number) {
  return line >= comment.start && line <= comment.end;
}
