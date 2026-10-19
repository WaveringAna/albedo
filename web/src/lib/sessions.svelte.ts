import { ApiError, listSessions, type Session } from './api';

export type Link = 'connecting' | 'online' | 'offline' | 'unauthorized';

const POLL_MS = 4000;

// One shared view of the daemon's root sessions. It refreshes while the tab
// is visible and stops when hidden, so a backgrounded tab costs nothing.
class Sessions {
  list = $state.raw<Session[]>([]);
  link = $state<Link>('connecting');
  loaded = $state(false);
  byId = $derived(new Map(this.list.map((session) => [session.id, session])));

  #timer: ReturnType<typeof setTimeout> | undefined;
  #inflight: AbortController | undefined;

  start() {
    document.addEventListener('visibilitychange', () => (document.hidden ? this.#pause() : this.refresh()));
    this.refresh();
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
    if (!document.hidden) this.#timer = setTimeout(() => this.refresh(), POLL_MS);
  }

  #pause() {
    clearTimeout(this.#timer);
    this.#inflight?.abort();
  }
}

export const sessions = new Sessions();
