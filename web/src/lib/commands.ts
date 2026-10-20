import { ApiError, sendCommand } from './api';

// Slash commands as the session's catalogue offers them (GET
// /sessions/{id}/catalog): skills and commands that become inputs, and
// commands that are daemon operations the client calls itself, binding
// their path, query, headers and body from the session record, the typed
// arguments, or literals (cli/internal/daemon/action_bindings.go does the
// same for the terminal).

interface Binding {
  source: 'literal' | 'session' | 'form' | 'row';
  value?: unknown;
  pointer?: string;
}

export interface Command {
  id: string;
  slash_name: string;
  description: string;
  arguments: { name: string; label: string; type: string; required: boolean; choices: unknown[] }[];
  caller_permissions: string[];
  delivery: 'input' | 'read' | 'mutation';
  command_id?: string;
  operation?: {
    method: string;
    path_template: string;
    path: Record<string, Binding>;
    query: Record<string, Binding>;
    headers: Record<string, Binding>;
    body: Record<string, Binding>;
  };
}

/** What a command answered, for the chat to show; inputs answer in the transcript instead. */
export interface Outcome {
  command: string;
  ok: boolean;
  result: unknown;
}

/** The commands a person may run in a session; empty until its runtime has loaded once. */
export async function catalogue(sessionId: string): Promise<Command[]> {
  const commands: Command[] = [];
  let query = 'kind=commands&limit=200';
  for (;;) {
    const response = await fetch(`/api/sessions/${sessionId}/catalog?${query}`, { headers: { accept: 'application/json' } });
    if (!response.ok) break;
    const loaded = (await response.json()).loaded;
    commands.push(...(loaded?.commands ?? []));
    if (!loaded?.next) break;
    query = `kind=commands&limit=200&next=${encodeURIComponent(loaded.next)}`;
  }
  return commands.filter((command) => command.caller_permissions.includes('human'));
}

/**
 * The command a typed line means, and the text after its name. One name may
 * be both a read and a change (`/model` shows the model, `/model x` sets it):
 * with nothing after the name the read wins, otherwise the change.
 */
export function parse(commands: Command[], line: string): { command: Command; rest: string } | null {
  const match = /^(\/[\w:.-]+)(?:\s+([\s\S]*))?$/.exec(line.trim());
  if (!match) return null;
  const candidates = commands.filter((command) => command.slash_name === match[1]);
  const rest = match[2]?.trim() ?? '';
  const order: Command['delivery'][] = rest ? ['mutation', 'input', 'read'] : ['read', 'input', 'mutation'];
  for (const delivery of order) {
    const command = candidates.find((candidate) => candidate.delivery === delivery);
    // A change that takes no arguments is chosen by any word after its name.
    if (command) return { command, rest: command.arguments.length ? rest : '' };
  }
  return null;
}

/** One entry per name for the menu, filtered by what has been typed of it. */
export function suggest(commands: Command[], typed: string): Command[] {
  const seen = new Set<string>();
  const unique = commands.filter((command) => !seen.has(command.slash_name) && seen.add(command.slash_name));
  const needle = typed.slice(1).toLowerCase();
  const starts = unique.filter((command) => command.slash_name.slice(1).startsWith(needle));
  const inside = unique.filter((command) => !starts.includes(command) && command.slash_name.includes(needle));
  return [...starts, ...inside];
}

/**
 * The text typed after a command's name as its arguments, the way the
 * terminal reads it (cli/internal/daemon/commands.go): words fill them in
 * order and the last takes the rest of the line, or a JSON object names them.
 */
export function form(command: Command, text: string): Record<string, unknown> {
  let rest = text.trim();
  if (command.arguments.length > 1 && rest.startsWith('{')) return JSON.parse(rest);
  const fields: Record<string, unknown> = {};
  command.arguments.forEach((argument, index) => {
    let word = rest;
    if (index < command.arguments.length - 1) {
      const end = rest.search(/\s/);
      [word, rest] = end < 0 ? [rest, ''] : [rest.slice(0, end), rest.slice(end).trim()];
    } else rest = '';
    if (!word && !argument.required) return;
    fields[argument.name] = argument.type === 'integer' || argument.type === 'number' ? Number(word) : argument.type === 'boolean' ? word === 'true' : word;
  });
  if (rest) throw new Error(`${command.slash_name} takes no arguments`);
  return fields;
}

function at(root: unknown, pointer = ''): unknown {
  let value = root;
  for (const token of pointer.split('/').slice(1)) {
    const key = token.replaceAll('~1', '/').replaceAll('~0', '~');
    value = value && typeof value === 'object' ? (value as Record<string, unknown>)[key] : undefined;
  }
  return value;
}

function resolve(binding: Binding, session: unknown, fields: Record<string, unknown>): unknown {
  if (binding.source === 'literal') return binding.value;
  return at(binding.source === 'session' ? session : binding.source === 'form' ? fields : undefined, binding.pointer);
}

/** Runs a command: an input goes to the session; an operation is called and its answer returned. */
export async function invoke(sessionId: string, command: Command, text: string, inputId: string): Promise<Outcome | null> {
  const fields = form(command, text);
  if (command.delivery === 'input') {
    await sendCommand(sessionId, inputId, command.command_id ?? command.slash_name, fields);
    return null;
  }
  const operation = command.operation!;
  const session = await fetch(`/api/sessions/${sessionId}`, { headers: { accept: 'application/json' } }).then((response) => response.json());
  let path = operation.path_template;
  for (const [name, binding] of Object.entries(operation.path)) path = path.replace(`{${name}}`, encodeURIComponent(String(resolve(binding, session, fields))));
  const query = new URLSearchParams();
  for (const [name, binding] of Object.entries(operation.query)) {
    const value = resolve(binding, session, fields);
    if (value !== undefined) query.set(name, String(value));
  }
  const headers: Record<string, string> = { accept: 'application/json' };
  for (const [name, binding] of Object.entries(operation.headers)) {
    const value = resolve(binding, session, fields);
    if (value !== undefined) headers[name] = String(value);
  }
  let body: Record<string, unknown> | undefined;
  for (const [pointer, binding] of Object.entries(operation.body)) {
    const value = resolve(binding, session, fields);
    if (value === undefined) continue;
    body ??= {};
    let target = body;
    const tokens = pointer.split('/').slice(1);
    for (const token of tokens.slice(0, -1)) target = (target[token] ??= {}) as Record<string, unknown>;
    target[tokens.at(-1)!] = value;
  }
  // A conditional PATCH edits a resource in place, as a merge patch.
  if (operation.method !== 'GET') {
    body ??= {};
    headers['content-type'] = operation.method === 'PATCH' ? 'application/merge-patch+json' : 'application/json';
  }
  const response = await fetch(`/api${path}${query.size ? `?${query}` : ''}`, { method: operation.method, headers, body: body && JSON.stringify(body) });
  const result = await response.json().catch(() => null);
  if (!response.ok) throw new ApiError(response.status, result?.code ?? 'http_error', result?.detail ?? response.statusText);
  return { command: command.slash_name, ok: true, result };
}
