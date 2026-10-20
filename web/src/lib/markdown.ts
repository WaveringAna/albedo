import { Marked, type TokenizerAndRendererExtension, type Tokens } from 'marked';

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

// Math and diagrams are left as placeholders carrying their source, shown as
// plain text until `enhance` (enhance.ts) draws them; KaTeX and Pele load
// only when a message needs them.

interface Math extends Tokens.Generic {
  text: string;
  display: boolean;
}

function mathHtml(text: string, display: boolean) {
  const tag = display ? 'div' : 'span';
  return `<${tag} class="math" data-display="${display ? 1 : 0}" data-tex="${escapeHtml(text)}">${escapeHtml(text)}</${tag}>`;
}

// $$…$$ or \[…\] standing as a block.
const mathBlock: TokenizerAndRendererExtension = {
  name: 'mathBlock',
  level: 'block',
  start: (src) => src.match(/\$\$|\\\[/)?.index,
  tokenizer(src) {
    const match = /^(?:\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\])[ \t]*(?:\n|$)/.exec(src);
    if (match) return { type: 'mathBlock', raw: match[0], text: (match[1] ?? match[2]).trim(), display: true };
  },
  renderer: (token) => mathHtml((token as Math).text, true),
};

// $…$, \(…\) or $$…$$ inside a line. A dollar amount is not maths: the
// opening $ must touch its text, the closing one too, and no digit may
// follow it ("$5 and $10" stays prose).
const mathInline: TokenizerAndRendererExtension = {
  name: 'mathInline',
  level: 'inline',
  start: (src) => src.match(/\$|\\\(/)?.index,
  tokenizer(src) {
    const display = /^\$\$([^\n]+?)\$\$/.exec(src);
    if (display) return { type: 'mathInline', raw: display[0], text: display[1].trim(), display: true };
    const match = /^\$(?![\s$])((?:\\.|[^\\$\n])+?)(?<!\s)\$(?!\d)/.exec(src) ?? /^\\\(([^\n]+?)\\\)/.exec(src);
    if (match) return { type: 'mathInline', raw: match[0], text: match[1], display: false };
  },
  renderer: (token) => mathHtml((token as Math).text, (token as Math).display),
};

const marked = new Marked({
  extensions: [mathBlock, mathInline],
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
    code({ text, lang }: Tokens.Code) {
      if (lang?.trim().toLowerCase() !== 'mermaid') return false;
      return `<div class="diagram" data-source="${escapeHtml(text)}"><pre><code>${escapeHtml(text)}</code></pre></div>`;
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
