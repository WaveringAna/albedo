import type { Session } from './api';
import { FRAME_MS, frames, type Mood } from './moods';

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

/**
 * Whether a session has a turn in hand. The daemon reports preparing,
 * generating (the model is thinking or writing), running (a tool),
 * compacting and interrupting; only idle and interrupted are at rest.
 */
export function busy(session: Session | undefined): boolean {
  const phase = session?.status?.phase;
  return !!phase && phase !== 'idle' && phase !== 'interrupted';
}

/** What a busy session is doing now, from its phase and the tail of its activity. */
export function liveMood(session: Session | undefined): Mood {
  switch (session?.status?.phase) {
    case 'preparing':
      return 'preparing';
    case 'compacting':
      return 'compacting';
    case 'interrupting':
      return 'stopping';
    case 'running':
      return 'working';
  }
  const line = session?.activity?.lines.findLast((candidate) => candidate.text.trim());
  return line?.kind === 'thinking' || !line ? 'thinking' : line.kind === 'tool' ? 'working' : 'responding';
}

// Each stretch of one mood draws its animation at random, as the TUI does, and
// keeps it while the mood holds.
const stretches = new Map<string, { mood: Mood; frames: string[] }>();

/** The frames a session's face plays for its current mood. */
export function liveFrames(sessionId: string, mood: Mood): string[] {
  let stretch = stretches.get(sessionId);
  if (stretch?.mood !== mood) stretches.set(sessionId, (stretch = { mood, frames: frames(mood, Math.floor(Math.random() * 2 ** 48)) }));
  return stretch.frames;
}
