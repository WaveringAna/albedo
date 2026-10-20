import { prefs } from './prefs.svelte';

// On a narrow screen the client is a plain chat app unless the canvas is
// asked for in settings: the session list, then one session's chat, with the
// browser's back button between them.
const NARROW = '(max-width: 760px)';

class Layout {
  #narrow = $state(matchMedia(NARROW).matches);
  phone = $derived(this.#narrow && !prefs.canvasOnPhone);
  /** The session open on the phone, or none for the list. */
  session = $state<string | null>(history.state?.session ?? null);

  constructor() {
    matchMedia(NARROW).addEventListener('change', (event) => (this.#narrow = event.matches));
    addEventListener('popstate', (event) => (this.session = event.state?.session ?? null));
  }

  open(sessionId: string) {
    if (this.session === sessionId) return;
    history.pushState({ session: sessionId }, '');
    this.session = sessionId;
  }

  back() {
    if (history.state?.session) history.back();
    else this.session = null;
  }
}

export const layout = new Layout();
