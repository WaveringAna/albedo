// The page only ever talks to its own origin: `/api` is forwarded to the
// daemon with its token by `albedo web` (or by Vite in development).

export type Phase = 'idle' | 'running' | 'interrupted' | 'stopping' | string;

export interface Session {
  id: string;
  name: string;
  workspace: string;
  root_id: string;
  parent_id: string | null;
  closed: boolean;
  created_at: string | null;
  activity_at: string | null;
  model: string | null;
  provider_profile: string | null;
  preferences: { pinned: boolean; archived: boolean };
  preview: { text: string; transcript_count: number } | null;
  status: { phase: Phase; blocking_reason: string | null } | null;
  /** The tail of what the session is doing right now: thinking, tool output, reply text. */
  activity?: { lines: { kind: string; text: string }[] };
}

interface Page<T> {
  items: T[];
  next: string | null;
}

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

async function request<T>(method: string, path: string, init: { signal?: AbortSignal; body?: unknown } = {}): Promise<T> {
  const response = await fetch(`/api${path}`, {
    method,
    signal: init.signal,
    headers: { accept: 'application/json', ...(init.body === undefined ? {} : { 'content-type': 'application/json' }) },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });
  if (!response.ok) {
    // The daemon answers problems as RFC 9457 bodies; `albedo web` uses {error}.
    const body = await response.json().catch(() => null);
    const problem = body?.error ?? body ?? {};
    throw new ApiError(response.status, problem.code ?? 'http_error', problem.detail ?? problem.title ?? response.statusText);
  }
  return response.json();
}

function get<T>(path: string, signal?: AbortSignal): Promise<T> {
  return request<T>('GET', path, { signal });
}

// Older sessions may lack either time; activity falls back to creation.
export function listSessions(signal?: AbortSignal): Promise<Session[]> {
  return get<Page<Session>>('/sessions?scope=roots&limit=200', signal).then((page) =>
    page.items.map((session) => ({ ...session, activity_at: session.activity_at ?? session.created_at })),
  );
}

export type EntryKind = 'user' | 'assistant' | 'thinking' | 'tool_call' | 'tool_result' | 'note' | 'image_fit' | 'compaction' | 'continuation';

export type ContentPart =
  | { kind: 'text'; text: string }
  | { kind: 'json'; field: string; value: unknown }
  | { kind: 'image'; image: { mime_type: string; width: number; height: number } }
  | { kind: 'trace'; trace: unknown }
  | { kind: 'reference'; reference: { url: string; field: string; bytes: number } };

export interface HistoryEntry {
  id: string;
  position: number;
  kind: EntryKind;
  turn_type: string | null;
  turn_id: string | null;
  input_id: string | null;
  created_at: string | null;
  content: ContentPart[];
  content_complete: boolean;
  mail: { sender_label: string; kind: string } | null;
  tool: { name: string; tool_call_id: string } | null;
  thinking_duration_ms: number | null;
}

export interface HistoryPage {
  items: HistoryEntry[];
  older: string | null;
  newer: string | null;
  high_water: number;
}

/** A page of a session's transcript, oldest first: the newest page, or the one before or after a position. */
export function readHistory(sessionId: string, at: { before?: number; after?: number } = {}, signal?: AbortSignal): Promise<HistoryPage> {
  const query = new URLSearchParams({ limit: '100' });
  if (at.before !== undefined) query.set('before', String(at.before));
  if (at.after !== undefined) query.set('after', String(at.after));
  return get(`/sessions/${sessionId}/history?${query}`, signal);
}

interface ContentPage {
  parts: { field: string; text: string }[];
  next: string | null;
}

/**
 * Every stored field of one entry in full, for content a history page only
 * referenced. `url` is the reference's own, which may name another entry.
 */
export async function readEntryContent(url: string): Promise<Record<string, string>> {
  const fields: Record<string, string> = {};
  let next: string | null = null;
  do {
    const query: string = next ? `?next=${encodeURIComponent(next)}` : '';
    const page: ContentPage = await get(`${url}${query}`);
    for (const part of page.parts) fields[part.field] = (fields[part.field] ?? '') + part.text;
    next = page.next;
  } while (next);
  return fields;
}

/** A UUIDv7: the daemon keys inputs by one, so a retried send is the same send. */
export function uuidv7(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  let time = Date.now();
  for (let i = 5; i >= 0; i--) {
    bytes[i] = time % 256;
    time = Math.floor(time / 256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function sendMessage(sessionId: string, inputId: string, text: string): Promise<unknown> {
  return request('PUT', `/sessions/${sessionId}/inputs/${inputId}`, { body: { kind: 'message', text } });
}
