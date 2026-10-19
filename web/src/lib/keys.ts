export const mac = /Mac|iPhone|iPad/.test(navigator.platform);

/** How the platform's command key reads next to a letter: ⌘K or Ctrl K. */
export function shortcut(key: string): string {
  return mac ? `⌘${key}` : `Ctrl ${key}`;
}

/** Whether a key press belongs to a text field rather than to the app. */
export function typing(event: KeyboardEvent): boolean {
  const target = event.target as HTMLElement | null;
  return !!target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName));
}
