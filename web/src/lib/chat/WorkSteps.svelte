<script lang="ts">
  import type { Block, Transcript } from '../transcript.svelte';
  import Markdown from './Markdown.svelte';
  import ToolStep from './ToolStep.svelte';

  // A turn's thinking and tool use between two messages, folded to one line
  // once it is done. The run still going stays open so it can be watched.
  let { steps, live, transcript }: { steps: Block[]; live: boolean; transcript: Transcript } = $props();

  let chosen = $state<boolean | null>(null);
  const open = $derived(chosen ?? live);
  const tools = $derived(steps.filter((step) => step.kind === 'tool'));
  const thoughts = $derived(steps.filter((step) => step.kind === 'thinking').length);
  const seconds = $derived(Math.round(steps.reduce((sum, step) => sum + (step.kind === 'thinking' ? (step.ms ?? 0) : 0), 0) / 1000));

  const label = $derived(
    [thoughts ? `${thoughts} ${thoughts === 1 ? 'thought' : 'thoughts'}` : '', tools.length ? `${tools.length} ${tools.length === 1 ? 'tool' : 'tools'}` : '']
      .filter(Boolean)
      .join(' · '),
  );

  // Thoughts show their first lines; a click shows the rest.
  let whole = $state(new Set<string>());
  function toggle(key: string) {
    const next = new Set(whole);
    if (!next.delete(key)) next.add(key);
    whole = next;
  }

  $effect(() => {
    if (open) transcript.expand(...tools.flatMap((step) => (step.kind === 'tool' ? [step.entry] : [])));
  });
</script>

<div class="work">
  <button class="summary" onclick={() => (chosen = !open)} aria-expanded={open}>
    <svg class="chevron" class:open viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M6 4l4 4-4 4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" /></svg>
    <span class:working={live}>{live ? 'Working' : 'Worked'}</span>
    <span class="count">{label}{seconds ? ` · thought ${seconds}s` : ''}</span>
  </button>
  {#if open}
    <div class="steps">
      {#each steps as step (step.key)}
        {#if step.kind === 'thinking'}
          <button class="thought" class:whole={whole.has(step.key)} onclick={() => toggle(step.key)}><Markdown text={step.text} /></button>
        {:else if step.kind === 'tool'}
          <ToolStep entry={step.entry} name={step.name} done={step.done} {transcript} />
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
  .count {
    color: var(--muted);
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
