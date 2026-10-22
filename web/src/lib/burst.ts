import type { components } from './api.gen';

// A burst is the work between two pieces of prose: thinking and tool calls,
// read as one past-tense line, the way the terminal client writes it
// (cli/internal/tui/burst.go): `thought 12s · read tui/{chat,moods}.go ·
// ran go test ×2`.

export type Trace = components['schemas']['ToolTrace'];

export interface Step {
  kind: 'thinking' | 'tool';
  ms?: number | null;
  name?: string;
  args?: Record<string, unknown>;
  trace?: Trace;
  failed?: boolean;
}

export interface Summary {
  text: string;
  failed: number;
  added: number;
  removed: number;
}

class Tally {
  counts = new Map<string, number>();
  add(key: string) {
    if (key) this.counts.set(key, (this.counts.get(key) ?? 0) + 1);
  }
  get keys() {
    return [...this.counts.keys()];
  }
  /** Each key, marking repeats: `go test ×4`. */
  counted() {
    return [...this.counts].map(([key, n]) => (n > 1 ? `${key} ×${n}` : key));
  }
}

const SUBCOMMANDED = new Set(['git', 'jj', 'go', 'cargo', 'gleam', 'npm', 'pnpm', 'yarn', 'bun', 'uv', 'pip', 'nix', 'brew', 'docker', 'kubectl', 'systemctl', 'tg', 'gh', 'make', 'just', 'npx']);
const PREAMBLE = new Set(['cd', 'export', 'set', 'source', '.']);

export function oneLine(text: string): string {
  return text.replace(/[\u0000-\u001f\u007f]+/g, ' ').replace(/\s+/g, ' ').trim();
}

function firstLine(text: string): string {
  return text.split('\n').map((line) => line.trim()).find(Boolean) ?? '';
}

/** What a command line runs: the program, and its subcommand when it has one. */
export function commandName(command: string): string {
  for (const part of command.replaceAll('\\\n', '').split(/&&|\|\||[;|\n]/)) {
    let fields = part.trim().split(/\s+/).filter(Boolean);
    while (fields.length && (/^[A-Za-z_][A-Za-z0-9_]*=/.test(fields[0]) || fields[0] === 'exec' || fields[0] === 'time')) fields = fields.slice(1);
    if (!fields.length || PREAMBLE.has(fields[0])) continue;
    let name = fields[0].startsWith('/') ? fields[0].split('/').pop()! : fields[0];
    if (fields.length > 1 && SUBCOMMANDED.has(name) && /^[a-z][a-z0-9-]*$/.test(fields[1])) name += ` ${fields[1]}`;
    return name;
  }
  return oneLine(command);
}

/** Paths named from the workspace, then from home. */
export function namer(workspace: string) {
  const home = workspace.match(/^\/(?:Users|home)\/[^/]+/)?.[0];
  return (target: string) => {
    if (workspace && target.startsWith(workspace + '/')) return target.slice(workspace.length + 1);
    if (home && target.startsWith(home + '/')) return '~' + target.slice(home.length);
    return target;
  };
}

/** Paths that share a parent read together: `tui/{chat,transcript}.go`. */
function pathGroups(paths: string[]): string[] {
  const groups = new Map<string, string[]>();
  for (const path of paths) {
    const trimmed = path.replace(/\/$/, '');
    const at = trimmed.lastIndexOf('/');
    const dir = trimmed.slice(0, at + 1);
    const name = trimmed.slice(at + 1) + (path.endsWith('/') ? '/' : '');
    groups.set(dir, [...(groups.get(dir) ?? []), name]);
  }
  const parentOf = (dir: string) => {
    const base = dir.replace(/\/$/, '').split('/').pop();
    return base ? `${dir.startsWith('/') ? '/' : ''}${base}/` : '';
  };
  // Two folders with the same last name keep their whole path, so they stay apart.
  const shared = new Map<string, number>();
  for (const dir of groups.keys()) shared.set(parentOf(dir), (shared.get(parentOf(dir)) ?? 0) + 1);
  return [...groups].map(([dir, names]) => ((shared.get(parentOf(dir)) ?? 0) > 1 ? dir : parentOf(dir)) + braced(names));
}

function braced(names: string[]): string {
  if (names.length === 1) return names[0];
  const ext = names[0].match(/\.[^./]+$/)?.[0] ?? '';
  if (ext && names.every((name) => name.endsWith(ext) && !name.endsWith('/'))) return `{${names.map((name) => name.slice(0, -ext.length)).join(',')}}${ext}`;
  return `{${names.join(',')}}`;
}

function formatSeconds(ms: number): string {
  const s = Math.floor(ms / 1000);
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`;
}

const MAX_ITEMS = 3;

function clause(verb: string, items: string[]): string | null {
  if (!items.length) return null;
  if (items.length > MAX_ITEMS + 1) return `${verb} ${items.slice(0, MAX_ITEMS).join(', ')} +${items.length - MAX_ITEMS}`;
  return `${verb} ${items.join(', ')}`;
}

/** The burst's one line, with counts kept apart so they can be coloured. */
export function summarize(steps: Step[], workspace: string): Summary {
  const name = namer(workspace);
  const read = new Tally(), edited = new Tally(), searched = new Tally(), ran = new Tally(), made = new Tally(), updated = new Tally(), python = new Tally(), used = new Tally();
  let thoughts = 0, thoughtMs = 0, failed = 0, added = 0, removed = 0;
  for (const step of steps) {
    if (step.kind === 'thinking') {
      thoughts++;
      thoughtMs += step.ms ?? 0;
      continue;
    }
    if (step.failed) failed++;
    const { activities = [], changes = [] } = step.trace ?? {};
    if (activities.length || changes.length) {
      for (const change of changes) {
        edited.add(name(change.path));
        if (change.kind === 'diff') {
          added += change.added;
          removed += change.removed;
        }
      }
      for (const activity of activities) {
        if (activity.kind === 'read') read.add(name(activity.target));
        else if (activity.kind === 'list') read.add(name(activity.target.replace(/\/?$/, '/')));
        else if (activity.kind === 'search') searched.add(oneLine(activity.target));
        else if (activity.kind === 'run') ran.add(commandName(activity.target));
        else if (activity.kind === 'artifact') (activity.artifact?.version === 1 ? made : updated).add(oneLine(activity.target));
      }
      continue;
    }
    const code = typeof step.args?.code === 'string' ? step.args.code : '';
    if (step.name === 'python') python.add(oneLine(firstLine(code)).slice(0, 48) || 'cell');
    else if (step.name) used.add(step.name);
  }
  const edits = edited.keys;
  const parts = [
    thoughts ? `thought${thoughtMs >= 1000 ? ' ' + formatSeconds(thoughtMs) : ''}` : null,
    clause('read', pathGroups(read.keys.filter((path) => !edits.includes(path)))),
    clause('searched', searched.keys),
    clause('edited', pathGroups(edits)),
    clause('ran', ran.counted()),
    clause('made', made.keys),
    clause('updated', updated.keys),
    clause('python', python.counted()),
    clause('used', used.counted()),
  ].filter(Boolean);
  return { text: parts.join(' · '), failed, added, removed };
}
