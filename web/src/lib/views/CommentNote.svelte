<script lang="ts">
  import type { Comment, Review } from '../review.svelte';

  // One comment beside the lines it is about: a field while it is written,
  // then its text with edit and remove.
  let { comment, review }: { comment: Comment; review: Review } = $props();
  // svelte-ignore state_referenced_locally
  let text = $state(comment.text);
  let field = $state<HTMLTextAreaElement>();

  $effect(() => {
    if (comment.draft) field?.focus();
  });

  const quick = ['explain this', 'why this way?', 'change this:'];

  function keydown(event: KeyboardEvent) {
    event.stopPropagation();
    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) review.save(comment.id, text);
    else if (event.key === 'Escape') comment.text ? review.save(comment.id, comment.text) : review.remove(comment.id);
  }
</script>

<div class="note" class:draft={comment.draft}>
  <span class="lines">{comment.start === comment.end ? `line ${comment.start}` : `lines ${comment.start}–${comment.end}`}{comment.side === 'deletions' ? ' (removed)' : ''}</span>
  {#if comment.draft}
    <textarea bind:this={field} bind:value={text} onkeydown={keydown} rows="2" placeholder="what should albedo know about these lines?"></textarea>
    <div class="actions">
      {#each quick as phrase (phrase)}
        <button class="chip" onclick={() => (text = text ? `${text} ${phrase}` : phrase)}>{phrase}</button>
      {/each}
      <span class="spacer"></span>
      <button onclick={() => (comment.text ? review.save(comment.id, comment.text) : review.remove(comment.id))}>cancel</button>
      <button class="primary" disabled={!text.trim()} onclick={() => review.save(comment.id, text)} title="add (⌘↵)">add</button>
    </div>
  {:else}
    <p>{comment.text}</p>
    <div class="actions">
      <span class="spacer"></span>
      <button onclick={() => review.edit(comment.id)}>edit</button>
      <button onclick={() => review.remove(comment.id)}>remove</button>
    </div>
  {/if}
</div>

<style>
  .note {
    width: 260px;
    padding: 8px 10px;
    color: var(--text);
    font-family: var(--sans);
    font-size: 12.5px;
    line-height: 1.45;
    white-space: normal;
    background: var(--surface);
    border-radius: 10px;
    box-shadow: var(--shadow-raised);
  }
  .note.draft {
    box-shadow: 0 0 0 2px var(--focus-ring), var(--shadow-raised);
  }
  .lines {
    color: var(--muted);
    font-size: 11px;
  }
  p {
    margin: 2px 0 0;
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }
  textarea {
    display: block;
    width: 100%;
    margin-top: 4px;
    padding: 6px 8px;
    color: var(--text);
    font: inherit;
    background: var(--field);
    border: 0;
    border-radius: 6px;
    outline: 0;
    resize: vertical;
    field-sizing: content;
    min-height: 44px;
  }
  .actions {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 4px;
    margin-top: 6px;
  }
  .spacer {
    flex: 1;
  }
  button {
    padding: 2px 8px;
    color: var(--muted);
    font: inherit;
    font-size: 11.5px;
    background: none;
    border: 0;
    border-radius: 6px;
    cursor: pointer;
  }
  button:hover {
    color: var(--text);
    background: var(--hover);
  }
  .chip {
    background: var(--well);
  }
  .primary {
    color: var(--surface);
    background: var(--accent);
  }
  .primary:hover {
    color: var(--surface);
    background: var(--accent);
    opacity: 0.9;
  }
  .primary:disabled {
    opacity: 0.35;
    cursor: default;
  }
</style>
