import type { ImageUpload } from '../api';

// Images in the composer, as the terminal client keeps them
// (cli/internal/tui/attachments.go): each attached image puts a numbered
// marker in the text at the cursor, deleting the marker drops the image, and
// sending numbers the images still marked 1..n in reading order.

export const MAX_IMAGES = 10;
const MARKER = /\[Image #(\d+)\]/g;
const TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];

export interface Attached extends ImageUpload {
  /** A data URL, for the thumbnail. */
  preview: string;
}

export function marker(n: number): string {
  return `[Image #${n}]`;
}

/** Whether a file is an image the daemon accepts. */
export function attachable(file: File): boolean {
  return TYPES.includes(file.type);
}

export async function readImage(file: File): Promise<Attached> {
  const preview = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
  return { mime_type: file.type as ImageUpload['mime_type'], data: preview.slice(preview.indexOf(',') + 1), preview };
}

/** The numbers of the images the text still marks, in reading order, each once. */
export function referenced(text: string, images: Map<number, Attached>): number[] {
  const numbers: number[] = [];
  for (const match of text.matchAll(MARKER)) {
    const n = Number(match[1]);
    if (images.has(n) && !numbers.includes(n)) numbers.push(n);
  }
  return numbers;
}

/** Renumbers the marked images 1..n and returns the text to match with the images in order. */
export function resolve(text: string, images: Map<number, Attached>): { text: string; images: Attached[] } {
  const numbers = referenced(text, images);
  const renumbered = new Map(numbers.map((n, index) => [n, index + 1]));
  return {
    text: text.replace(MARKER, (found, n) => (renumbered.has(Number(n)) ? marker(renumbered.get(Number(n))!) : found)),
    images: numbers.map((n) => images.get(n)!),
  };
}

/** The text without one image's markers. */
export function unmark(text: string, n: number): string {
  return text.replaceAll(` ${marker(n)}`, '').replaceAll(marker(n), '');
}
