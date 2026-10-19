import { readEntryContent, readHistory, sendMessage, uuidv7, type ContentPart, type HistoryEntry } from './api';

// One session's transcript as the chat shows it. Entries arrive as history
// pages; blocks are what the chat draws. Content a page only referenced is
// fetched when it is needed: message text at once, tool output on opening.

export type Block =
  | { kind: 'user'; key: string; text: string; from: string | null; state: 'sent' | 'sending' | 'failed'; error?: string }
  | { kind: 'assistant'; key: string; text: string }
  | { kind: 'thinking'; key: string; text: string; ms: number | null }
  | { kind: 'tool'; key: string; name: string; entry: HistoryEntry; done: boolean }
  | { kind: 'note'; key: string; text: string }
  | { kind: 'compaction'; key: string; text: string };

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
    for (const entry of this.entries) {
      const text = textOf(entry.content);
      switch (entry.kind) {
        case 'user':
          blocks.push({ kind: 'user', key: entry.id, text, from: entry.mail?.sender_label ?? (entry.turn_type && entry.turn_type !== 'user' ? entry.turn_type : null), state: 'sent' });
          break;
        case 'assistant':
          if (text.trim()) blocks.push({ kind: 'assistant', key: entry.id, text });
          break;
        case 'thinking':
          if (text.trim()) blocks.push({ kind: 'thinking', key: entry.id, text, ms: entry.thinking_duration_ms });
          break;
        case 'tool_call':
          // A call shows until its result replaces it.
          if (entry.tool && !results.has(entry.tool.tool_call_id)) blocks.push({ kind: 'tool', key: entry.id, name: entry.tool.name, entry, done: false });
          break;
        case 'tool_result':
          if (entry.tool) blocks.push({ kind: 'tool', key: entry.id, name: entry.tool.name, entry, done: true });
          break;
        case 'note':
        case 'image_fit':
          if (text.trim()) blocks.push({ kind: 'note', key: entry.id, text });
          break;
        case 'compaction':
          blocks.push({ kind: 'compaction', key: entry.id, text });
          break;
      }
    }
    for (const send of this.pending) {
      blocks.push({ kind: 'user', key: `pending:${send.id}`, text: send.text, from: null, state: send.error ? 'failed' : 'sending', error: send.error });
    }
    return blocks;
  }
}

function group(blocks: Block[]): Group[] {
  const groups: Group[] = [];
  for (const block of blocks) {
    const last = groups.at(-1);
    if (block.kind === 'thinking' || block.kind === 'tool') {
      if (last?.kind === 'work') last.steps.push(block);
      else groups.push({ kind: 'work', key: `work:${block.key}`, steps: [block] });
    } else groups.push(block);
  }
  return groups;
}
