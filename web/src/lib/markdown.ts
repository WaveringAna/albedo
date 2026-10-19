import { Marked, type Tokens } from 'marked';

// Transcripts carry text from models and tools, so nothing in them may run
// in this page: raw HTML is shown as text, links keep only web and mail
// schemes, and images become links instead of loading.

const escapes: Record<string, string> = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

export function escapeHtml(text: string): string {
  return text.replace(/[&<>"']/g, (char) => escapes[char]);
}

function safeHref(href: string): string | null {
  try {
    const url = new URL(href, 'https://invalid.example/');
    return ['http:', 'https:', 'mailto:'].includes(url.protocol) && url.host !== 'invalid.example' ? url.href : null;
  } catch {
    return null;
  }
}

const marked = new Marked({
  gfm: true,
  breaks: false,
  renderer: {
    html({ text }: Tokens.HTML | Tokens.Tag) {
      return escapeHtml(text);
    },
    link({ href, tokens }: Tokens.Link) {
      const text = this.parser.parseInline(tokens);
      const safe = safeHref(href);
      return safe ? `<a href="${escapeHtml(safe)}" target="_blank" rel="noopener noreferrer">${text}</a>` : text;
    },
    image({ href, text }: Tokens.Image) {
      const safe = safeHref(href);
      return safe ? `<a href="${escapeHtml(safe)}" target="_blank" rel="noopener noreferrer">${escapeHtml(text || safe)}</a>` : escapeHtml(text);
    },
  },
});

export function renderMarkdown(text: string): string {
  return marked.parse(text, { async: false });
}
