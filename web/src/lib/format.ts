const units: [Intl.RelativeTimeFormatUnit, number][] = [
  ['year', 31536000],
  ['month', 2592000],
  ['week', 604800],
  ['day', 86400],
  ['hour', 3600],
  ['minute', 60],
];

/** "4m", "2h", "3d": short enough for a list row. */
export function ago(iso: string | null, now = Date.now()): string {
  if (!iso) return '';
  const seconds = Math.max(0, (now - Date.parse(iso)) / 1000);
  if (seconds < 45) return 'now';
  for (const [unit, size] of units) {
    if (seconds >= size) return `${Math.floor(seconds / size)}${unit === 'month' ? 'mo' : unit[0]}`;
  }
  return `${Math.round(seconds / 60)}m`;
}

/** The workspace's last folder, with home shown as ~ and a remote host before it. */
export function place(workspace: string): string {
  const remote = /^(?:[^/@]+@)?([^/:~][^/:]*):(\/.*)$/.exec(workspace);
  if (remote) return `${remote[1]}:${place(remote[2])}`;
  const trimmed = workspace.replace(/\/+$/, '');
  if (/^\/(Users|home)\/[^/]+$/.test(trimmed)) return '~';
  return trimmed.split('/').pop() || trimmed;
}

/** The full path with the home folder shortened to ~. */
export function homePath(workspace: string): string {
  return workspace.replace(/^\/(Users|home)\/[^/]+(?=\/|$)/, '~');
}

/**
 * How well a query fits a text, lower is better: 0 starts the text, 1 starts
 * a word, 2 appears anywhere, 3 only as scattered letters in order, and -1 not at all.
 */
export function score(query: string, text: string): number {
  const needle = query.trim().toLowerCase();
  const haystack = text.toLowerCase();
  if (!needle) return 0;
  const at = haystack.indexOf(needle);
  if (at === 0) return 0;
  if (at > 0) return /[\s/._:-]/.test(haystack[at - 1]) ? 1 : 2;
  return matches(needle, haystack) ? 3 : -1;
}

/** The entries that fit the query, best first; ties keep their order. */
export function rank<T>(entries: T[], query: string, text: (entry: T) => string): T[] {
  return entries
    .map((entry) => ({ entry, fit: score(query, text(entry)) }))
    .filter(({ fit }) => fit >= 0)
    .sort((a, b) => a.fit - b.fit)
    .map(({ entry }) => entry);
}

/** Whether every character of the query appears in order in the text. */
export function matches(query: string, text: string): boolean {
  let at = 0;
  const haystack = text.toLowerCase();
  for (const char of query.toLowerCase().replace(/\s+/g, '')) {
    at = haystack.indexOf(char, at) + 1;
    if (at === 0) return false;
  }
  return true;
}
