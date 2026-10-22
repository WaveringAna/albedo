<script lang="ts">
  import type { Session } from '../api';
  import { summarize, type Step } from '../burst';
  import { jsonField, madeIn, type Block, type Made, type Transcript } from '../transcript.svelte';
  import Markdown from './Markdown.svelte';
  import ToolStep from './ToolStep.svelte';

  // A turn's thinking and tool use between two messages, read as one line of
  // what it did, the way the terminal writes it. The run still going stays
  // open, with albedo's face, so it can be watched.
  let {
    steps,
    live,
    transcript,
    session,
    onreview,
    onartifact,
  }: {
    steps: Block[];
    live: boolean;
    transcript: Transcript;
    session: Session | undefined;
    onreview: (turnId: string, from: number, path?: string) => void;
    onartifact: (made: Made) => void;
  } = $props();

  let chosen = $state<boolean | null>(null);
  let element = $state<HTMLElement>();
  const open = $derived(chosen ?? live);
  const tools = $derived(steps.flatMap((step) => (step.kind === 'tool' ? [step.entry] : [])));
  const summary = $derived(
    summarize(
      steps.flatMap((step): Step[] => {
        if (step.kind === 'thinking') return [{ kind: 'thinking', ms: step.ms }];
        if (step.kind === 'tool') return [{ kind: 'tool', name: step.name, args: jsonField(step.entry, 'arguments') as Record<string, unknown> | undefined, trace: step.trace, failed: step.failed }];
        return [];
      }),
      session?.workspace ?? '',
    ),
  );

  // What a call touched lives in its trace, which a page may only reference;
  // fetch it once the line comes into view.
  $effect(() => {
    if (!element) return;
    const observer = new IntersectionObserver(([entry]) => entry.isIntersecting && transcript.expand(...tools), { rootMargin: '200px' });
    observer.observe(element);
    return () => observer.disconnect();
  });

  // The counts open the turn's review, on the first file this stretch changed.
  const turnId = $derived(tools.find((entry) => entry.turn_id)?.turn_id ?? null);
  function review() {
    const from = turnId ? transcript.turnStart(turnId) : null;
    const path = steps.flatMap((step) => (step.kind === 'tool' ? (step.trace?.changes ?? []) : [])).find((change) => change.path)?.path;
    if (turnId && from !== null) onreview(turnId, from, path);
  }

  // Each artifact this stretch made or revised, at its newest version, as a
  // line that opens it.
  const made = $derived.by(() => {
    const newest = new Map<string, Made>();
    for (const step of steps) if (step.kind === 'tool') for (const item of madeIn(step.trace)) newest.set(item.id, item);
    return [...newest.values()];
  });

  // Thoughts show their first lines; a click shows the rest.
  let whole = $state(new Set<string>());
  function toggle(key: string) {
    const next = new Set(whole);
    if (!next.delete(key)) next.add(key);
    whole = next;
  }

</script>

<div class="work" bind:this={element}>
  <div class="head">
  <button class="summary" onclick={() => (chosen = !open)} aria-expanded={open} title={summary.text}>
    <svg class="chevron" class:open viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M6 4l4 4-4 4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" /></svg>
    <span class="line">{summary.text || 'worked'}</span>
    {#if summary.failed}<span class="failed">{summary.failed} failed</span>{/if}
  </button>
  {#if summary.added || summary.removed}
    <button class="counts" onclick={review} title="show these changes in the review"><span class="added">+{summary.added}</span> <span class="removed">−{summary.removed}</span></button>
  {/if}
  </div>
  {#each made as item (item.id)}
    <button class="artifact" onclick={() => onartifact(item)} title="open {item.title}">
      <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><rect x="2" y="3" width="12" height="10" rx="2" fill="none" stroke="currentColor" stroke-width="1.4" /><path d="M2 6h12" stroke="currentColor" stroke-width="1.4" /></svg>
      <span class="verb">{item.version === 1 ? 'made' : 'updated'}</span>
      <span class="title">{item.title}</span>
      {#if item.version > 1}<span class="version">v{item.version}</span>{/if}
    </button>
  {/each}
  {#if open}
    <div class="steps">
      {#each steps as step (step.key)}
        {#if step.kind === 'thinking'}
          <button class="thought" data-entry={step.key} class:whole={whole.has(step.key)} onclick={() => toggle(step.key)}><Markdown text={step.text} /></button>
        {:else if step.kind === 'tool'}
          <ToolStep entry={step.entry} name={step.name} done={step.done} {transcript} />
        {:else if step.kind === 'progress'}
          <p class="running"><span class="spinner" aria-label="running"></span><span class="name">{step.name}</span><span class="preview">{step.preview.split('\n').find((line) => line.trim())?.trim() ?? ''}</span></p>
        {/if}
      {/each}
    </div>
  {/if}
</div>

<style>
  .summary {
    display: flex;
    align-items: center;
    gap: 6px;
    width: 100%;
    min-width: 0;
    text-align: left;
    padding: 2px 6px;
    margin: 0 -6px;
    color: var(--muted);
    font: inherit;
    font-size: 12.5px;
    background: none;
    border: 0;
    border-radius: 6px;
    cursor: pointer;
    transition: background-color 100ms ease, color 100ms ease;
  }
  .summary:hover {
    color: var(--text);
    background: var(--hover);
  }
  .chevron {
    transition: transform 160ms cubic-bezier(0.23, 1, 0.32, 1);
  }
  .chevron.open {
    transform: rotate(90deg);
  }
  .chevron {
    flex: none;
  }
  .line {
    min-width: 0;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .failed {
    flex: none;
    color: var(--danger);
  }
  .head {
    display: flex;
    align-items: center;
    gap: 2px;
    min-width: 0;
  }
  .head .summary {
    flex: 1;
    width: auto;
  }
  .counts {
    flex: none;
    padding: 2px 6px;
    font: inherit;
    font-variant-numeric: tabular-nums;
    background: none;
    border: 0;
    border-radius: 6px;
    cursor: pointer;
    transition: background-color 120ms ease;
  }
  .counts:hover {
    background: var(--hover);
  }
  .added {
    color: var(--added);
  }
  .removed {
    color: var(--danger);
  }
  .steps {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 2px;
    margin: 6px 0 0;
    padding: 8px 12px;
    background: var(--well);
    border-radius: 10px;
  }
  .artifact {
    display: flex;
    align-items: center;
    gap: 6px;
    max-width: 100%;
    margin: 4px -6px 0;
    padding: 4px 8px 4px 6px;
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
  .artifact:hover {
    color: var(--text);
    background: var(--hover);
  }
  .artifact svg {
    flex: none;
    color: var(--accent);
  }
  .artifact .title {
    min-width: 0;
    overflow: hidden;
    color: var(--accent);
    font-weight: 560;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .artifact .version {
    flex: none;
    color: var(--faint);
    font-variant-numeric: tabular-nums;
  }
  .running {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
    margin: 0;
    padding: 3px 0;
    color: var(--muted);
    font-size: 12.5px;
  }
  .running .name {
    flex: none;
    font-weight: 560;
  }
  .running .preview {
    min-width: 0;
    overflow: hidden;
    font-family: var(--mono);
    font-size: 11.5px;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  .spinner {
    flex: none;
    width: 9px;
    height: 9px;
    border: 1.5px solid color-mix(in oklab, var(--accent) 25%, transparent);
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }
  @keyframes spin {
    to { transform: rotate(360deg); }
  }
  .thought {
    display: -webkit-box;
    margin: 2px 0 6px;
    padding: 0;
    overflow: hidden;
    color: var(--muted);
    font: inherit;
    font-size: 12.5px;
    text-align: left;
    background: none;
    border: 0;
    cursor: pointer;
    -webkit-box-orient: vertical;
    -webkit-line-clamp: 3;
    line-clamp: 3;
  }
  .thought.whole {
    display: block;
  }
</style>
