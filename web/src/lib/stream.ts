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

/** Follows a session's stream until stopped, reconnecting with the saved cursor. Returns the stop function. */
export function follow(sessionId: string, onBatch: (batch: Batch) => void, onState: (connected: boolean) => void): () => void {
  const controller = new AbortController();
  let after: { generation: string; cursor: number } | null = null;
  let delay = RETRY.first;

  const run = async () => {
    while (!controller.signal.aborted) {
      const query = new URLSearchParams({ tail: '0' });
      if (after) {
        query.set('after_generation', after.generation);
        query.set('after_seq', String(after.cursor));
      }
      try {
        const response = await fetch(`/api/sessions/${sessionId}?${query}`, { headers: { accept: 'text/event-stream' }, signal: controller.signal });
        if (!response.ok || !response.body) throw new Error(`stream answered ${response.status}`);
        onState(true);
        delay = RETRY.first;
        for await (const data of frames(response.body)) {
          const batch = JSON.parse(data) as Batch;
          if (!Array.isArray(batch.events)) continue;
          onBatch(batch);
          after = { generation: batch.generation, cursor: batch.cursor };
        }
      } catch (error) {
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
