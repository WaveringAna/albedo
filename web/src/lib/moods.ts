// The faces albedo makes, ported from the terminal client (cli/internal/tui/moods.go)
// so the same turn wears the same face in both clients: the pools, their
// order and the seeded pick are kept identical.

export type Mood =
  | 'preparing'
  | 'thinking'
  | 'responding'
  | 'working'
  | 'compacting'
  | 'stopping'
  | 'connecting'
  | 'done'
  | 'quick'
  | 'long'
  | 'tired'
  | 'failed'
  | 'stopped';

// A phase owns a pool of animations and each turn plays one. Only eyes,
// mouth and what follows a face move between frames.
const animations: Partial<Record<Mood, string[][]>> = {
  preparing: [['(・・ )', '( ・・)']],
  thinking: [
    ['( ˘ω˘ )', '( ˘ω˘ ).', '( ˘ω˘ )..', '( ˘ω˘ )...'],
    ['(・ω・ )', '( ・ω・)', '(・ω・ )?', '( ・ω・)?'],
    ['(´-ω-`)', '(´･ω･`)', '(´-ω-`)', '(´･ω･`)!'],
  ],
  responding: [
    ['(ˊᗜˋ )', '(ˊ-ˋ )', '( ˊᗜˋ)', '( ˊ-ˋ)'],
    ['(˶ᵔ ᗜ ᵔ˶)', '(˶ᵔ ᵕ ᵔ˶)'],
    ['(・ᗜ・)', '(・-・)', '(・ᗜ・)ﾉ', '(・-・)ﾉ'],
  ],
  working: [
    ['(˶•ᴗ•)ｶﾀ', '(˶•ᴗ•)ｶﾀｶﾀ', '(˶•ᴗ•)ｶﾀｶﾀｶﾀ'],
    ['(・_・ )', '( ・_・)', '(・ᴗ・ )✧'],
    ['(っ•ᴗ•)っ･', '(っ•ᴗ•)っ ･', '(っ•ᴗ•)っ  ･'],
    ['ヽ(･ω･)ﾉ', 'ヾ(･ω･)ﾉ'],
    ['(๑•ᴗ•)', '(๑•ᴗ•)✧', '(๑•ᴗ•) ✧'],
  ],
  compacting: [['(>_<)', '(>.<)']],
  stopping: [['(・_・;)']],
  connecting: [
    ['(・ω・)ﾉ', '(・ω・)ﾉ ･', '(・ω・)ﾉ ･･', '(・ω・)ﾉ ･･･'],
    ['( ˘ω˘ )～', '( ˘ω˘ )～～', '( ˘ω˘ )～～～'],
    ['(っ•ᴗ•)っ', '(っ•ᴗ•)っ ･', '(っ•ᴗ•)っ ･ﾟ', '(っ•ᴗ•)っ ･ﾟ✧'],
  ],
};

// An outcome owns a pool of faces and each turn shows one of them.
const faces: Partial<Record<Mood, string[]>> = {
  done: ['(˶ᵔ ᵕ ᵔ˶)', '(๑˃ᴗ˂)', 'ヽ(・∀・)ﾉ', '(ᵔᴥᵔ)', '(っ˘ω˘ς)', '(◕‿◕)', '(✿◠‿◠)', '(o´ω｀o)', '☻_☻', 'ᶘ ᵒᴥᵒᶅ'],
  quick: ['(・ω・)ノ', '(｀・ω・´)', '(^_−)☆', '(^▽^)'],
  long: ['(ง ˃ᴗ˂)ง', '(๑˃ᴗ˂)✧', '(ˊᗜˋ*)✧', 'o(≧∀≦)o', '(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧'],
  tired: ['(￣ー￣;)ゞ', '(・ω・;)ゞ', '( ˘ᴗ˘ )ﾌｩ', '(´-ω-`)zzZ', '_(:3 」∠)_', '(︶ω︶)', '(-＿- )ノ', '(n˘v˘•)¬'],
  failed: ['(╥﹏╥)', '(｡•︿•｡)', '(っ- ‸ – ς)', '(ಥ﹏ಥ)', '(╥_╥)', '☹_☹', '(ಠ~ಠ)', '(ಡ_ಡ)', '(ತಎತ)', '(ತ_ತ)', '(ಥдಥ)'],
  stopped: ['(・_・;)', '(°ロ°)', '(￣□￣;)', '(ಠ_ಠ)', '(°Д°)'],
};

/** How long each frame of an animation shows. */
export const FRAME_MS = 500;

const MASK = (1n << 64n) - 1n;
const PRIME = 1099511628211n;

/** 64-bit FNV-1a over the UTF-8 bytes of s, starting from h, as the Go client computes it. */
function fnv1a(h: bigint, s: string): bigint {
  for (const byte of new TextEncoder().encode(s)) h = ((h ^ BigInt(byte)) * PRIME) & MASK;
  return h;
}

/** Chooses from n by seed, salted by the mood, so one turn's picks for different moods do not move in step. */
function pick(mood: Mood, seed: number, n: number): number {
  return Number(fnv1a(BigInt.asUintN(64, BigInt(Math.trunc(seed))), mood) % BigInt(n));
}

/** A stable face for a finished turn: the same seed always shows the same face. */
export function face(mood: Mood, seed: number): string {
  const set = faces[mood] ?? faces.done!;
  return set[pick(mood, seed, set.length)];
}

/** The frames of the animation a turn plays for a mood. */
export function frames(mood: Mood, seed: number): string[] {
  const pool = animations[mood] ?? animations.working!;
  return pool[pick(mood, seed, pool.length)];
}

/** How a finished turn ended and how long it took. */
export function outcome(failed: boolean, stopped: boolean, elapsedMs: number): Mood {
  if (stopped) return 'stopped';
  if (failed) return 'failed';
  if (elapsedMs > 10 * 60_000) return 'tired';
  if (elapsedMs >= 3 * 60_000) return 'long';
  if (elapsedMs > 0 && elapsedMs < 4_000) return 'quick';
  return 'done';
}

export function formatElapsed(ms: number): string {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  return `${Math.floor(s / 3600)}h ${Math.floor(s / 60) % 60}m`;
}

/** How long you were away, in the largest whole unit. */
export function formatGap(ms: number): string {
  const m = Math.floor(ms / 60_000);
  if (m < 60) return `${m}m later`;
  if (m < 48 * 60) return `${Math.floor(m / 60)}h later`;
  return `${Math.floor(m / (24 * 60))}d later`;
}
