<script lang="ts">
  import { renderMarkdown } from '../markdown';

  let { text }: { text: string } = $props();
  const html = $derived(renderMarkdown(text));
</script>

<!-- renderMarkdown escapes raw HTML and unsafe links; see markdown.ts. -->
<div class="markdown">{@html html}</div>

<style>
  .markdown {
    overflow-wrap: anywhere;
  }
  .markdown :global(:first-child) {
    margin-top: 0;
  }
  .markdown :global(:last-child) {
    margin-bottom: 0;
  }
  .markdown :global(p),
  .markdown :global(ul),
  .markdown :global(ol),
  .markdown :global(pre),
  .markdown :global(blockquote),
  .markdown :global(table) {
    margin: 0 0 0.75em;
  }
  .markdown :global(ul),
  .markdown :global(ol) {
    padding-left: 1.4em;
  }
  .markdown :global(li + li) {
    margin-top: 0.25em;
  }
  .markdown :global(h1),
  .markdown :global(h2),
  .markdown :global(h3),
  .markdown :global(h4) {
    margin: 1.1em 0 0.5em;
    font-size: 1em;
    font-weight: 620;
  }
  .markdown :global(h1) {
    font-size: 1.15em;
  }
  .markdown :global(a) {
    color: var(--accent);
    text-decoration: underline;
    text-decoration-color: color-mix(in oklab, var(--accent) 35%, transparent);
    text-underline-offset: 2px;
  }
  .markdown :global(code) {
    padding: 0.1em 0.35em;
    font-family: var(--mono);
    font-size: 0.88em;
    background: var(--hover);
    border-radius: 4px;
  }
  .markdown :global(pre) {
    padding: 10px 12px;
    overflow-x: auto;
    font-size: 12px;
    line-height: 1.5;
    background: var(--well);
    border-radius: 10px;
    scrollbar-width: thin;
  }
  .markdown :global(pre code) {
    padding: 0;
    font-size: inherit;
    background: none;
  }
  .markdown :global(blockquote) {
    padding: 8px 14px;
    color: var(--muted);
    background: var(--well);
    border-radius: 10px;
  }
  .markdown :global(table) {
    display: block;
    max-width: 100%;
    overflow-x: auto;
    font-size: 0.92em;
    border-collapse: collapse;
  }
  .markdown :global(th),
  .markdown :global(td) {
    padding: 4px 10px;
    text-align: left;
    border: 1px solid var(--line);
  }
  .markdown :global(hr) {
    height: 0;
    margin: 1.4em 0;
    border: 0;
  }
</style>
