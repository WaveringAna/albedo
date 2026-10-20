// The tie being drawn from a note's grip to whatever it will be about, while
// the pointer is down. The canvas draws it; the note sets it.
export const tying = $state<{ note: string | null; x: number; y: number }>({ note: null, x: 0, y: 0 });
