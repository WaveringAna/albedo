// A session's live event stream: GET /sessions/{id} as server-sent events.
// Each frame is a batch {generation, cursor, events, snapshot?}. The stream
// resumes after the last batch it fully handled; a new generation, or a
// cursor the daemon no longer holds, comes back as a reset with a snapshot.
// See robot-docs/sessions.md, "Stream failures and recovery".

export interface StreamEvent {
  type: string;
  sequence?: number;
  data: any;
}

export interface Batch {
  generation: string;
  cursor: number;
  events: StreamEvent[];
  snapshot?: any;
}

const RETRY = { first: 500, most: 5000 };

/**
 * Reads server-sent events from a daemon resource until stopped, asking
 * again after an ordinary end or a failure with a growing wait. `resume`
 * names the query that continues after a handled batch. Returns the stop
 * function.
 */
function subscribe<T>(path: string, resume: (batch: T) => Record<string, string> | null, onBatch: (batch: T) => void, onState: (connected: boolean) => void): () => void {
  const controller = new AbortController();
  let after: Record<string, string> | null = null;
  let delay = RETRY.first;

  const run = async () => {
    while (!controller.signal.aborted) {
      const [base, given = ''] = path.split('?');
      const query = new URLSearchParams(given);
      for (const [key, value] of Object.entries(after ?? {})) query.set(key, value);
      try {
        const response = await fetch(`/api${base}?${query}`, { headers: { accept: 'text/event-stream' }, signal: controller.signal });
        if (!response.ok || !response.body) throw new Error(`stream answered ${response.status}`);
        onState(true);
        delay = RETRY.first;
        for await (const data of frames(response.body)) {
          const batch = JSON.parse(data) as T;
          onBatch(batch);
          after = resume(batch) ?? after;
        }
      } catch {
        if (controller.signal.aborted) return;
      }
      // An ordinary end is a restart or a deletion; either way, ask again.
      onState(false);
      await new Promise((resolve) => setTimeout(resolve, delay));
      delay = Math.min(RETRY.most, delay * 2);
    }
  };
  run();
  return () => controller.abort();
}

/** Follows one session's stream, resuming after the last batch it fully handled. */
export function follow(sessionId: string, onBatch: (batch: Batch) => void, onState: (connected: boolean) => void): () => void {
  return subscribe<Batch>(
    `/sessions/${sessionId}?tail=0`,
    (batch) => (batch.generation ? { after_generation: batch.generation, after_seq: String(batch.cursor) } : null),
    (batch) => Array.isArray(batch.events) && onBatch(batch),
    onState,
  );
}

/**
 * Follows the session list: each session's status and activity as it
 * changes, and invalidations when sessions come, go or change. Every
 * connection starts with a reset, so there is nothing to resume.
 */
export function followSessions(onEvents: (events: StreamEvent[]) => void, onState: (connected: boolean) => void): () => void {
  return subscribe<{ events?: StreamEvent[] }>('/sessions?scope=roots', () => null, (batch) => Array.isArray(batch.events) && onEvents(batch.events), onState);
}

/** The data of each server-sent event in a body: lines after `data:`, joined, up to a blank line. */
async function* frames(body: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let pending = '';
  let data: string[] = [];
  for (;;) {
    const { value, done } = await reader.read();
    if (done) return;
    pending += decoder.decode(value, { stream: true });
    let end: number;
    while ((end = pending.indexOf('\n')) >= 0) {
      const line = pending.slice(0, end).replace(/\r$/, '');
      pending = pending.slice(end + 1);
      if (line === '') {
        if (data.length) yield data.join('\n');
        data = [];
      } else if (line.startsWith('data:')) data.push(line.slice(line.startsWith('data: ') ? 6 : 5));
    }
  }
}
