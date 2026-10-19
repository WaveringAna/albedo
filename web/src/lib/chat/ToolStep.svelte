<script lang="ts">
  import type { HistoryEntry } from '../api';
  import { jsonField, type Transcript } from '../transcript.svelte';

  // One tool call in a turn's steps: a line naming what ran, opening to the
  // code and what came back. Full content is fetched on opening.
  let { entry, name, done, transcript }: { entry: HistoryEntry; name: string; done: boolean; transcript: Transcript } = $props();

  let open = $state(false);
  let loading = $state(false);

  const args = $derived(jsonField(entry, 'arguments') as Record<string, unknown> | undefined);
  const result = $derived(parseResult(jsonField(entry, 'result')));
  const summary = $derived(describe(name, args) ?? (entry.content_complete ? '' : '…'));

  function describe(tool: string, input: Record<string, unknown> | undefined): string | null {
    if (!input) return null;
    const first = Object.values(input).find((value) => typeof value === 'string') as string | undefined;
    const code = typeof input.code === 'string' ? input.code : first;
    return code?.split('\n').find((line) => line.trim())?.trim() ?? null;
  }

  // The python tool answers with a JSON record; show its output and value.
  function parseResult(value: unknown): { text: string; failed: boolean } | null {
    if (value === undefined) return null;
    let record = value;
    if (typeof value === 'string') {
      try {
        record = JSON.parse(value);
      } catch {
        return { text: value, failed: false };
      }
    }
    if (record && typeof record === 'object' && 'output' in record) {
      const cell = record as { output?: string; value?: string; status?: string };
      return { text: [cell.output, cell.value].filter(Boolean).join('\n').trim(), failed: cell.status === 'error' };
    }
    return { text: typeof record === 'string' ? record : JSON.stringify(record, null, 2), failed: false };
  }

  async function toggle() {
    open = !open;
    if (open && !entry.content_complete && !loading) {
      loading = true;
      await transcript.expand(entry).finally(() => (loading = false));
    }
  }
</script>

<div class="tool" class:open class:failed={result?.failed}>
  <button class="line" onclick={toggle} aria-expanded={open}>
    {#if !done}<span class="spinner" aria-label="running"></span>{/if}
    <span class="name">{name}</span>
    {#if result?.failed}<span class="failed-label">failed</span>{/if}
    <span class="summary">{summary}</span>
  </button>
  {#if open}
    <div class="detail">
      {#if loading}
        <p class="muted">loading…</p>
      {:else}
        {#if args}
          <pre class="code">{typeof args.code === 'string' ? args.code : JSON.stringify(args, null, 2)}</pre>
        {/if}
        {#if result?.text}
          <pre class="output">{result.text}</pre>
        {:else if done}
          <p class="muted">no output</p>
        {/if}
      {/if}
    </div>
  {/if}
</div>

<style>
  .line {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    min-width: 0;
    padding: 3px 6px;
    margin: 0 -6px;
    color: var(--muted);
    font: inherit;
    font-size: 12.5px;
    text-align: left;
    background: none;
    border: 0;
    border-radius: 6px;
    cursor: pointer;
    transition: background-color 100ms ease, color 100ms ease;
  }
  .line:hover {
    color: var(--text);
    background: var(--hover);
  }
  .failed-label {
    flex: none;
    color: var(--danger);
  }
  .spinner {
    flex: none;
    width: 9px;
    height: 9px;
    margin: 0 -2px;
    border: 1.5px solid color-mix(in oklab, var(--accent) 25%, transparent);
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }
  @keyframes spin {
    to { transform: rotate(360deg); }
  }
  .name {
    flex: none;
    font-weight: 560;
  }
  .summary {
    min-width: 0;
    overflow: hidden;
    font-family: var(--mono);
    font-size: 11.5px;
    color: var(--muted);
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .detail {
    display: grid;
    gap: 6px;
    margin: 4px 0 8px;
  }
  pre {
    max-height: 320px;
    margin: 0;
    padding: 8px 10px;
    overflow: auto;
    font-family: var(--mono);
    font-size: 11.5px;
    line-height: 1.5;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    background: var(--surface);
    border-radius: 8px;
    scrollbar-width: thin;
  }
  .output {
    color: var(--muted);
  }
  .failed .output {
    color: var(--danger);
  }
  .muted {
    margin: 0;
    color: var(--muted);
    font-size: 12px;
  }
</style>
