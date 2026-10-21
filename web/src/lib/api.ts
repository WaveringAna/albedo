// The page only ever talks to its own origin: `/api` is forwarded to the
// daemon with its token by `albedo web` (or by Vite in development).

import type { components } from './api.gen';

export type Phase = components['schemas']['SessionStatus']['phase'];

export type Session = components['schemas']['SessionSummary'];

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

async function request<T>(method: string, path: string, init: { signal?: AbortSignal; body?: unknown; headers?: Record<string, string> } = {}): Promise<T> {
  const response = await fetch(`/api${path}`, {
    method,
    signal: init.signal,
    headers: { accept: 'application/json', ...(init.body === undefined ? {} : { 'content-type': 'application/json' }), ...init.headers },
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

export type EntryKind = HistoryEntry['kind'];

export type ContentPart = HistoryEntry['content'][number];

export type HistoryEntry = components['schemas']['HistoryEntry'];

export type HistoryPage = components['schemas']['HistoryPage'];

/** A page of a session's transcript, oldest first: the newest page, or the one before or after a position. */
export function readHistory(sessionId: string, at: { before?: number; after?: number } = {}, signal?: AbortSignal): Promise<HistoryPage> {
  const query = new URLSearchParams({ limit: '100' });
  if (at.before !== undefined) query.set('before', String(at.before));
  if (at.after !== undefined) query.set('after', String(at.after));
  return get(`/sessions/${sessionId}/history?${query}`, signal);
}

type ContentPage = components['schemas']['EntryContentPage'];

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

/**
 * Puts text on the clipboard. Over plain http from another device the page
 * is not a secure context and has no Clipboard API, so it falls back to the
 * older copy command.
 */
export async function copyText(text: string): Promise<void> {
  if (navigator.clipboard) return navigator.clipboard.writeText(text);
  const field = Object.assign(document.createElement('textarea'), { value: text });
  field.style.cssText = 'position:fixed;opacity:0';
  document.body.append(field);
  field.select();
  const copied = document.execCommand('copy');
  field.remove();
  if (!copied) throw new Error('copying is not available here');
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

/**
 * Stops the session's running turn and any inputs waiting behind it. The run
 * and input order are read fresh, so a stop never reaches a later run.
 */
export async function interruptSession(sessionId: string): Promise<void> {
  const session = await get<components['schemas']['Session']>(`/sessions/${sessionId}`);
  await request('POST', `/sessions/${sessionId}/interrupt`, { body: { run_id: session.status.run_id, through_input_order: session.input_order } });
}

/** One background job as the kernel's job book keeps it; times are wall-clock milliseconds. */
export type Job = components['schemas']['JobRecord'];

/** A page of a job's output: the bytes from `offset` to `next_offset`, cut on characters. */
export type JobPage = components['schemas']['JobOutputPage'];

/** The session's jobs, newest first, finished ones too while the kernel keeps their output. */
export function listJobs(sessionId: string, signal?: AbortSignal): Promise<Job[]> {
  return get<components['schemas']['JobRecordCollection']>(`/extensions/run/sessions/${sessionId}/jobs/recent`, signal).then((page) => page.items);
}

/** A page of a job's output: from `offset`, or the last page when there is none. */
export function readJobOutput(sessionId: string, jobId: string, offset?: number, signal?: AbortSignal): Promise<JobPage> {
  const query = new URLSearchParams({ limit: '65536' });
  if (offset !== undefined) query.set('offset', String(offset));
  return get(`/extensions/run/sessions/${sessionId}/jobs/${jobId}/output?${query}`, signal);
}

/** Stops the job's process group; the kernel answers once it is gone. */
export async function stopJob(sessionId: string, jobId: string): Promise<void> {
  await request('POST', `/extensions/run/sessions/${sessionId}/jobs/${jobId}/stop`);
}

/** A folder sessions have worked in, most used first. */
export type RecentWorkspace = components['schemas']['RecentWorkspace'];

export type Directory = components['schemas']['WorkspaceDirectory'];

export function recentWorkspaces(): Promise<RecentWorkspace[]> {
  return get<Page<RecentWorkspace>>('/workspaces?limit=200').then((page) => page.items);
}

export function browse(location: string): Promise<Directory> {
  return get<Directory>(`/workspaces?location=${encodeURIComponent(location)}&limit=200`);
}

/** A provider profile: an account and endpoint, with the model and effort a new session starts on. */
export type Profile = Pick<components['schemas']['ProviderProfile'], 'extension' | 'model' | 'effort'> & { id: string };

export async function profiles(): Promise<{ fallback: string | null; profiles: Profile[] }> {
  const providers = await get<components['schemas']['ProviderSettings']>('/settings?group=providers');
  const list = Object.entries(providers.profiles).map(([id, profile]) => ({ ...profile, id }));
  return { fallback: providers.default_profile, profiles: list.sort((a, b) => a.id.localeCompare(b.id)) };
}

export type Model = components['schemas']['Model'];

export function models(profile: string): Promise<Model[]> {
  return get<Page<Model>>(`/models?provider_profile=${encodeURIComponent(profile)}`).then((page) => page.items);
}

export type Choice = Pick<components['schemas']['SessionConfiguration'], 'provider_profile' | 'model' | 'effort'>;

/** Starts a session in a folder; null choices take the defaults. */
export function createSession(workspace: string, choice: Choice): Promise<Session> {
  // If-None-Match makes the PUT a create: it never replaces a session.
  return request<Session>('PUT', `/sessions/${uuidv7()}`, { body: { kind: 'new', workspace, ...choice }, headers: { 'if-none-match': '*' } });
}

/** Changes a session's profile, model or effort, against the configuration it was read at. */
export async function configureSession(sessionId: string, change: Partial<Choice>): Promise<void> {
  const url = `/sessions/${sessionId}?view=configuration`;
  const response = await fetch(`/api${url}`, { headers: { accept: 'application/json' } });
  if (!response.ok) throw new ApiError(response.status, 'http_error', response.statusText);
  const etag = response.headers.get('etag') ?? '';
  await request('PATCH', url, { body: change, headers: { 'content-type': 'application/merge-patch+json', 'if-match': etag } });
}

/** A session's current choice of profile, model and effort. */
export function sessionChoice(sessionId: string): Promise<Choice> {
  return get<Choice>(`/sessions/${sessionId}?view=configuration`);
}

export type ImageUpload = components['schemas']['ImageUpload'];

/** Sends a slash command or skill as an input, with its arguments as a form. */
export function sendCommand(sessionId: string, inputId: string, commandId: string, fields: Record<string, unknown>): Promise<unknown> {
  return request('PUT', `/sessions/${sessionId}/inputs/${inputId}`, { body: { kind: 'command', command_id: commandId, arguments: fields } });
}

export function sendMessage(sessionId: string, inputId: string, text: string, images: ImageUpload[] = []): Promise<unknown> {
  const body = images.length ? { kind: 'message', text, images } : { kind: 'message', text };
  return request('PUT', `/sessions/${sessionId}/inputs/${inputId}`, { body });
}
