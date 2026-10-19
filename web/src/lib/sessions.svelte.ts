import { ApiError, listSessions, type Session } from './api';
import { followSessions, type StreamEvent } from './stream';

export type Link = 'connecting' | 'online' | 'offline' | 'unauthorized';

// While the list's stream is up, it carries every change and the list is
// read again only when it says to (and once a minute, in case). Without it
// the list is polled.
const POLL_MS = { streaming: 60_000, polling: 4000 };

// One shared view of the daemon's root sessions. It stops while the tab is
// hidden, so a backgrounded tab costs nothing.
class Sessions {
  list = $state.raw<Session[]>([]);
  link = $state<Link>('connecting');
  loaded = $state(false);
  streaming = $state(false);
  byId = $derived(new Map(this.list.map((session) => [session.id, session])));

  #timer: ReturnType<typeof setTimeout> | undefined;
  #inflight: AbortController | undefined;
  #stopStream: (() => void) | null = null;
  #soon: ReturnType<typeof setTimeout> | undefined;

  start() {
    document.addEventListener('visibilitychange', () => (document.hidden ? this.#pause() : this.#resume()));
    this.#resume();
  }

  async refresh() {
    clearTimeout(this.#timer);
    this.#inflight?.abort();
    const controller = (this.#inflight = new AbortController());
    try {
      this.list = await listSessions(controller.signal);
      this.link = 'online';
      this.loaded = true;
    } catch (error) {
      if (controller.signal.aborted) return;
      this.link = error instanceof ApiError && error.status === 401 ? 'unauthorized' : 'offline';
    }
    if (!document.hidden) this.#timer = setTimeout(() => this.refresh(), this.streaming ? POLL_MS.streaming : POLL_MS.polling);
  }

  #resume() {
    this.#stopStream ??= followSessions(
      (events) => this.#apply(events),
      (connected) => {
        this.streaming = connected;
        if (!connected) this.#later(0);
      },
    );
    this.refresh();
  }

  #pause() {
    clearTimeout(this.#timer);
    clearTimeout(this.#soon);
    this.#inflight?.abort();
    this.#stopStream?.();
    this.#stopStream = null;
    this.streaming = false;
  }

  /** Reads the list again shortly, once for a burst of changes. */
  #later(ms = 150) {
    clearTimeout(this.#soon);
    this.#soon = setTimeout(() => this.refresh(), ms);
  }

  #apply(events: StreamEvent[]) {
    let patched = this.list;
    for (const event of events) {
      if (event.type === 'activity') {
        const { session_id: id, status, activity } = event.data ?? {};
        const at = patched.findIndex((session) => session.id === id);
        if (at < 0) {
          this.#later();
          continue;
        }
        const current = patched[at];
        const next: Session = { ...current, status: status ?? current.status, activity: activity ?? current.activity, activity_at: activity?.observed_at ?? current.activity_at };
        patched = patched.map((session, index) => (index === at ? next : session));
      } else if (event.type === 'reset' || event.type === 'overflow' || event.type === 'invalidate') this.#later();
    }
    if (patched !== this.list) this.list = patched;
  }
}

export const sessions = new Sessions();
