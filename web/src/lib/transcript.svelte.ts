import { readEntryContent, readHistory, sendMessage, uuidv7, type ContentPart, type HistoryEntry } from './api';
import type { Trace } from './burst';
import { follow, type Batch } from './stream';
import { formatGap, outcome, type Mood } from './moods';

// One session's transcript as the chat shows it. Entries arrive as history
// pages; blocks are what the chat draws. Content a page only referenced is
// fetched when it is needed: message text at once, tool output on opening.

export type Block =
  | { kind: 'user'; key: string; text: string; from: string | null; gap: string | null; state: 'sent' | 'sending' | 'failed'; error?: string }
  | { kind: 'assistant'; key: string; text: string; plate: boolean }
  | { kind: 'thinking'; key: string; text: string; ms: number | null }
  | { kind: 'tool'; key: string; name: string; entry: HistoryEntry; done: boolean; trace?: Trace; failed: boolean }
  | { kind: 'note'; key: string; text: string }
  | { kind: 'compaction'; key: string; text: string }
  | { kind: 'end'; key: string; mood: Mood; seed: number; elapsedMs: number; tools: number; text: string }
  | { kind: 'progress'; key: string; name: string; preview: string };

/** Output the session is writing now, before it commits: one message of thinking or reply. */
interface Live {
  id: string;
  kind: 'text' | 'thinking';
  text: string;
}

/** A tool call running now, as its progress reports it. */
interface Progress {
  id: string;
  /** The model's id for the call, which its tool_call entry carries too. */
  call: string;
  name: string;
  preview: string;
}

interface Turn {
  id: string | null;
  start: number;
  last: number;
  tools: number;
  answered: boolean;
  /** The turn's last reply, which its copy action copies. */
  text: string;
}

/** The pause before your message that earns a "later" note, as in the TUI. */
const AWAY_MS = 30 * 60_000;

/** A turn's run of thinking and tool use, drawn as one collapsible step list. */
export type Group = { kind: 'work'; key: string; steps: Block[] } | Block;

interface Pending {
  id: string;
  text: string;
  error?: string;
}

function textOf(content: ContentPart[]): string {
  return content.map((part) => (part.kind === 'text' ? part.text : '')).join('');
}

/** The value of a JSON field of an entry, if the page carried it inline. */
export function jsonField(entry: HistoryEntry, field: string): unknown {
  for (const part of entry.content) if (part.kind === 'json' && part.field === field) return part.value;
  return undefined;
}

function traceOf(entry: HistoryEntry): Trace | undefined {
  for (const part of entry.content) if (part.kind === 'trace') return part.trace as Trace;
  return undefined;
}

/** A python cell that raised, read from its result envelope. */
function failedTool(entry: HistoryEntry): boolean {
  const result = jsonField(entry, 'result');
  if (typeof result !== 'string') return false;
  try {
    return JSON.parse(result)?.status === 'error';
  } catch {
    return false;
  }
}

function progressOf(progress: any): Progress {
  return { id: progress?.call_id ?? '', call: progress?.tool_call_id ?? '', name: progress?.name ?? 'tool', preview: progress?.preview?.text ?? '' };
}

const at = (entry: HistoryEntry) => (entry.created_at ? Date.parse(entry.created_at) : 0);

function referenced(entry: HistoryEntry): boolean {
  return entry.content.some((part) => part.kind === 'reference' && !part.reference.field.startsWith('image-'));
}

/** Replaces an entry's references with the content they name. */
export async function hydrate(entry: HistoryEntry): Promise<HistoryEntry> {
  if (!referenced(entry)) return { ...entry, content_complete: true };
  const urls = new Set(entry.content.flatMap((part) => (part.kind === 'reference' ? [part.reference.url] : [])));
  const loaded = new Map<string, Record<string, string>>();
  await Promise.all([...urls].map(async (url) => loaded.set(url, await readEntryContent(url))));
  const content = entry.content.map((part): ContentPart => {
    if (part.kind !== 'reference' || part.reference.field.startsWith('image-')) return part;
    const { url, field } = part.reference;
    const raw = loaded.get(url)?.[field] ?? '';
    if (field === 'text') return { kind: 'text', text: raw };
    if (field === 'trace') return { kind: 'trace', trace: JSON.parse(raw) };
    return { kind: 'json', field, value: JSON.parse(raw) };
  });
  return { ...entry, content, content_complete: true };
}

export class Transcript {
  entries = $state.raw<HistoryEntry[]>([]);
  pending = $state.raw<Pending[]>([]);
  loading = $state(true);
  /** Whether the session is busy, so its newest turn is not signed off yet. */
  running = $state(false);
  /** The phase the stream last reported, fresher than the session list's. */
  phase = $state<string | null>(null);
  streaming = $state(false);
  live = $state.raw<Live[]>([]);
  progress = $state.raw<Progress[]>([]);
  #stop: (() => void) | null = null;
  #settle: ReturnType<typeof setTimeout> | undefined;
  more = $state(false);
  error = $state<string | null>(null);

  blocks = $derived(this.#blocks());
  groups = $derived(group(this.blocks));

  #expanding = new Set<string>();
  #polling = false;

  constructor(readonly sessionId: string) {}

  async load() {
    try {
      const page = await readHistory(this.sessionId);
      this.entries = await this.#hydrateText(page.items);
      this.more = page.older !== null;
      this.error = null;
    } catch (error) {
      this.error = String((error as Error).message ?? error);
    } finally {
      this.loading = false;
    }
  }

  async loadOlder() {
    const first = this.entries[0];
    if (!first || !this.more) return;
    const page = await readHistory(this.sessionId, { before: first.position });
    const known = new Set(this.entries.map((entry) => entry.id));
    this.entries = [...(await this.#hydrateText(page.items.filter((entry) => !known.has(entry.id)))), ...this.entries];
    this.more = page.older !== null;
  }

  /** Reads everything after the newest entry. One poll runs at a time. */
  async poll() {
    if (this.#polling) return;
    this.#polling = true;
    try {
      for (;;) {
        const last = this.entries.at(-1);
        const page = await readHistory(this.sessionId, last ? { after: last.position } : {});
        const known = new Set(this.entries.map((entry) => entry.id));
        const fresh = page.items.filter((entry) => !known.has(entry.id));
        if (fresh.length) {
          const arrived = await this.#hydrateText(fresh);
          this.entries = [...this.entries, ...arrived];
          const answered = new Set(arrived.map((entry) => entry.input_id));
          this.pending = this.pending.filter((send) => !answered.has(send.id));
        }
        if (!page.newer || !fresh.length) return;
      }
    } finally {
      this.#polling = false;
    }
  }

  /** Follows the session's stream: live output as it is written, and history as it commits. */
  attach() {
    this.#stop ??= follow(this.sessionId, (batch) => this.#apply(batch), (connected) => (this.streaming = connected));
  }

  detach() {
    this.#stop?.();
    this.#stop = null;
    clearTimeout(this.#settle);
  }

  #apply(batch: Batch) {
    for (const event of batch.events) {
      const data = event.data ?? {};
      switch (event.type) {
        case 'reset': {
          const snapshot = batch.snapshot ?? {};
          this.phase = snapshot.status?.phase ?? null;
          this.live = (snapshot.active_output ?? []).flatMap((output: any) =>
            output.kind === 'text' || output.kind === 'thinking' ? [{ id: output.message_id, kind: output.kind, text: output.text ?? '…' }] : [],
          );
          this.progress = (snapshot.current_progress ?? []).map(progressOf);
          this.#commit(null);
          break;
        }
        case 'status':
          this.phase = data.phase ?? null;
          if (this.phase === 'idle' || this.phase === 'interrupted') this.#commit(null);
          break;
        case 'text':
        case 'thinking': {
          const at = this.live.findIndex((item) => item.id === data.message_id);
          if (at < 0) this.live = [...this.live, { id: data.message_id, kind: event.type, text: data.text }];
          else this.live = this.live.map((item, index) => (index === at ? { ...item, text: item.text + data.text } : item));
          break;
        }
        case 'tool_progress': {
          const next = progressOf(data.progress);
          this.progress = [...this.progress.filter((item) => item.id !== next.id), next];
          break;
        }
        case 'tool':
          this.progress = this.progress.filter((item) => item.id !== data.progress_call_id);
          this.#commit(null);
          break;
        case 'committed':
          this.#commit(data.replaces_all_live ? 'all' : (data.replaces_live_ids ?? []));
          break;
        case 'message':
        case 'note':
          this.#commit(null);
          break;
      }
    }
  }

  /**
   * Reads what committed, then drops the live output it replaces, so a reply
   * never blinks out between its last delta and its history entry.
   */
  #commit(replaces: 'all' | string[] | null) {
    clearTimeout(this.#settle);
    this.#settle = setTimeout(async () => {
      await this.poll().catch(() => {});
      if (replaces === 'all') this.live = [];
      else if (replaces?.length) this.live = this.live.filter((item) => !replaces.includes(item.id));
      if (this.phase === 'idle' || this.phase === 'interrupted') [this.live, this.progress] = [[], []];
    }, 60);
  }

  async send(text: string) {
    const send = { id: uuidv7(), text };
    this.pending = [...this.pending, send];
    await this.#deliver(send);
  }

  async retry(id: string) {
    const send = this.pending.find((candidate) => candidate.id === id);
    if (!send) return;
    this.pending = this.pending.map((candidate) => (candidate.id === id ? { id, text: send.text } : candidate));
    await this.#deliver(send);
  }

  discard(id: string) {
    this.pending = this.pending.filter((send) => send.id !== id);
  }

  /** Puts tool entries' full arguments and output in place of their references. */
  async expand(...entries: HistoryEntry[]) {
    const waiting = entries.filter((entry) => !entry.content_complete && !this.#expanding.has(entry.id) && referenced(entry));
    if (!waiting.length) return;
    for (const entry of waiting) this.#expanding.add(entry.id);
    try {
      const full = new Map((await Promise.all(waiting.map(hydrate))).map((entry) => [entry.id, entry]));
      this.entries = this.entries.map((candidate) => full.get(candidate.id) ?? candidate);
    } finally {
      for (const entry of waiting) this.#expanding.delete(entry.id);
    }
  }

  async #deliver(send: Pending) {
    try {
      await sendMessage(this.sessionId, send.id, send.text);
    } catch (error) {
      const message = String((error as Error).message ?? error);
      this.pending = this.pending.map((candidate) => (candidate.id === send.id ? { ...candidate, error: message } : candidate));
    }
  }

  // Message text is what the chat is for; fetch it up front. Tool content waits.
  #hydrateText(entries: HistoryEntry[]) {
    return Promise.all(entries.map((entry) => (['user', 'assistant', 'thinking', 'note', 'compaction'].includes(entry.kind) ? hydrate(entry) : entry)));
  }

  #blocks(): Block[] {
    const results = new Set(this.entries.flatMap((entry) => (entry.kind === 'tool_result' && entry.tool ? [entry.tool.tool_call_id] : [])));
    const blocks: Block[] = [];
    let turn = null as Turn | null;
    let previous = 0;
    let speaker = '';

    // A turn signs off with a face once the next one starts or the session rests.
    const signOff = () => {
      if (!turn || (!turn.answered && !turn.tools)) return;
      const elapsedMs = Math.max(0, turn.last - turn.start);
      blocks.push({ kind: 'end', key: `end:${turn.id}`, mood: outcome(false, false, elapsedMs), seed: turn.last, elapsedMs, tools: turn.tools, text: turn.text });
    };

    for (const entry of this.entries) {
      const text = textOf(entry.content);
      if (!turn || entry.turn_id !== turn.id) {
        signOff();
        turn = { id: entry.turn_id, start: at(entry), last: at(entry), tools: 0, answered: false, text: '' };
      }
      turn.last = Math.max(turn.last, at(entry));
      switch (entry.kind) {
        case 'user': {
          const gap = previous && at(entry) - previous >= AWAY_MS ? formatGap(at(entry) - previous) : null;
          const from = entry.mail?.sender_label?.toLowerCase() ?? (entry.turn_type && !['user', 'chat'].includes(entry.turn_type) ? entry.turn_type : null);
          blocks.push({ kind: 'user', key: entry.id, text, from, gap, state: 'sent' });
          speaker = 'you';
          break;
        }
        case 'assistant':
          if (!text.trim()) break;
          blocks.push({ kind: 'assistant', key: entry.id, text, plate: speaker !== 'albedo' });
          speaker = 'albedo';
          turn.answered = true;
          turn.text = text;
          break;
        case 'thinking':
          if (text.trim()) blocks.push({ kind: 'thinking', key: entry.id, text, ms: entry.thinking_duration_ms });
          break;
        case 'tool_call':
          // A call shows until its result replaces it.
          if (entry.tool && !results.has(entry.tool.tool_call_id)) blocks.push({ kind: 'tool', key: entry.id, name: entry.tool.name, entry, done: false, failed: false });
          break;
        case 'tool_result':
          if (!entry.tool) break;
          turn.tools++;
          blocks.push({ kind: 'tool', key: entry.id, name: entry.tool.name, entry, done: true, trace: traceOf(entry), failed: failedTool(entry) });
          break;
        case 'note':
        case 'image_fit':
          if (text.trim()) blocks.push({ kind: 'note', key: entry.id, text });
          break;
        case 'compaction':
          blocks.push({ kind: 'compaction', key: entry.id, text });
          break;
      }
      if (at(entry)) previous = at(entry);
    }
    if (!this.running && !this.pending.length) signOff();
    for (const item of this.live) {
      if (!item.text.trim()) continue;
      if (item.kind === 'thinking') blocks.push({ kind: 'thinking', key: `live:${item.id}`, text: item.text, ms: null });
      else blocks.push({ kind: 'assistant', key: `live:${item.id}`, text: item.text, plate: speaker !== 'albedo' });
    }
    // A call whose entry has committed already shows as that entry.
    const called = new Set(this.entries.flatMap((entry) => (entry.kind === 'tool_call' && entry.tool ? [entry.tool.tool_call_id] : [])));
    for (const item of this.progress) {
      if (!called.has(item.call)) blocks.push({ kind: 'progress', key: `progress:${item.id}`, name: item.name, preview: item.preview });
    }
    for (const send of this.pending) {
      blocks.push({ kind: 'user', key: `pending:${send.id}`, text: send.text, from: null, gap: null, state: send.error ? 'failed' : 'sending', error: send.error });
    }
    return blocks;
  }
}

function group(blocks: Block[]): Group[] {
  const groups: Group[] = [];
  for (const block of blocks) {
    const last = groups.at(-1);
    if (block.kind === 'thinking' || block.kind === 'tool' || block.kind === 'progress') {
      if (last?.kind === 'work') last.steps.push(block);
      else groups.push({ kind: 'work', key: `work:${block.key}`, steps: [block] });
    } else groups.push(block);
  }
  return groups;
}
