import type { Session } from './api';
import { FRAME_MS, frame, type Mood } from './moods';

// One clock for every animated face on the page, so they step together and
// a page with many windows still wakes only twice a second.
class Clock {
  tick = $state(0);
  #timer: ReturnType<typeof setInterval> | undefined;
  #users = 0;

  use() {
    if (this.#users++ === 0) this.#timer = setInterval(() => this.tick++, FRAME_MS);
    return () => {
      if (--this.#users === 0) clearInterval(this.#timer);
    };
  }
}

export const clock = new Clock();

/** What a running session is doing now, read from the tail of its activity. */
export function liveMood(session: Session | undefined): Mood {
  const line = session?.activity?.lines.findLast((candidate) => candidate.text.trim());
  if (line?.kind === 'thinking') return 'thinking';
  if (line?.kind === 'text' || line?.kind === 'assistant') return 'responding';
  return 'working';
}

// Each stretch of one mood draws its animation at random, as the TUI does, and
// keeps it while the mood holds.
const stretches = new Map<string, { mood: Mood; seed: number }>();

export function liveFace(sessionId: string, mood: Mood, tick: number): string {
  let stretch = stretches.get(sessionId);
  if (stretch?.mood !== mood) stretches.set(sessionId, (stretch = { mood, seed: Math.floor(Math.random() * 2 ** 48) }));
  return frame(mood, stretch.seed, tick);
}
