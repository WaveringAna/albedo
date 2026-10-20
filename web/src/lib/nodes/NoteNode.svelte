<script lang="ts">
  import type { NodeProps } from '@xyflow/svelte';
  import { describe, targetAt } from '../anchors';
  import type { NoteWindow } from '../board.svelte';
  import { boards } from '../boards.svelte';
  import { sendable, sendNotes } from '../notes';
  import { sessions } from '../sessions.svelte';
  import { tying } from '../tie.svelte';

  // A note on the canvas. Drag its top edge to move it; drag the tie from
  // its corner onto a window, a message or step in a chat, or lines in a
  // diff to make it about that (drop it on empty canvas to set it loose).
  // A sent note stays, faded, until it is dismissed.
  let { id, data, selected }: NodeProps<NoteWindow> = $props();
  const board = $derived(boards.board);
  let field = $state<HTMLTextAreaElement>();
  let sending = $state(false);
  let problem = $state('');

  const about = $derived(
    describe(data.target, (window) => {
      const node = board?.nodes.find((candidate) => candidate.id === window);
      if (!node || node.type === 'note') return 'a closed window';
      const name = sessions.byId.get(node.data.sessionId)?.name || 'untitled session';
      return node.type === 'review' ? `the review of ${name}` : name;
    }),
  );
  const ready = $derived(!!board && !data.sent && sendable(board, { id, data } as NoteWindow));

  // A note just made is for writing in. The canvas keeps a node hidden
  // until it has measured it, and a hidden field cannot take focus, so try
  // for a few frames.
  $effect(() => {
    if (!field || !board?.fresh.delete(id)) return;
    let tries = 10;
    let frame = 0;
    const attempt = () => {
      field?.focus();
      if (document.activeElement !== field && --tries > 0) frame = requestAnimationFrame(attempt);
    };
    frame = requestAnimationFrame(attempt);
    return () => cancelAnimationFrame(frame);
  });

  async function send() {
    if (!board || !ready) return;
    sending = true;
    problem = '';
    try {
      await sendNotes(board, [{ id, data } as NoteWindow]);
    } catch (error) {
      problem = String((error as Error).message ?? error);
    } finally {
      sending = false;
    }
  }

  function keydown(event: KeyboardEvent) {
    event.stopPropagation();
    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) send();
    if (event.key === 'Escape') field?.blur();
  }

  function tie(event: PointerEvent) {
    event.preventDefault();
    event.stopPropagation();
    const grip = event.currentTarget as HTMLElement;
    grip.setPointerCapture(event.pointerId);
    Object.assign(tying, { note: id, x: event.clientX, y: event.clientY });
    const move = (moved: PointerEvent) => Object.assign(tying, { x: moved.clientX, y: moved.clientY });
    const end = (ended: PointerEvent) => {
      grip.removeEventListener('pointermove', move);
      grip.removeEventListener('pointerup', end);
      grip.removeEventListener('pointercancel', cancel);
      tying.note = null;
      board?.updateNote(id, { target: targetAt(ended.clientX, ended.clientY), sent: false });
    };
    const cancel = () => {
      grip.removeEventListener('pointermove', move);
      grip.removeEventListener('pointerup', end);
      grip.removeEventListener('pointercancel', cancel);
      tying.note = null;
    };
    grip.addEventListener('pointermove', move);
    grip.addEventListener('pointerup', end);
    grip.addEventListener('pointercancel', cancel);
  }
</script>

<article class="note" class:selected class:sent={data.sent} class:loose={!data.target}>
  <header class="note-handle">
    <button class="grip nodrag" title="drag onto what this note is about" aria-label="tie this note to something" onpointerdown={tie}>
      <svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><circle cx="4" cy="12" r="2" fill="currentColor" /><path d="M5.5 10.5 12 4M8.5 4H12v3.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" /></svg>
    </button>
    <span class="about" title={data.target?.kind === 'window' ? about : (data.target?.quote ?? about)}>{about}</span>
    <button class="dismiss nodrag" title="dismiss" aria-label="dismiss note" onclick={() => board?.remove(id)}>
      <svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg>
    </button>
  </header>
  <textarea
    bind:this={field}
    class="nodrag nowheel"
    value={data.text}
    readonly={data.sent}
    oninput={(event) => board?.updateNote(id, { text: event.currentTarget.value })}
    onkeydown={keydown}
    rows="2"
    placeholder={data.target ? 'what about it?' : 'a note… tie it to something to send it'}
  ></textarea>
  {#if data.sent}
    <footer><span class="state">sent ✓</span></footer>
  {:else if data.target}
    <footer>
      {#if problem}<span class="problem" title={problem}>not sent</span>{/if}
      <span class="spacer"></span>
      <button class="send nodrag" disabled={!ready || sending} onclick={send} title="send to albedo (⌘↵)">send</button>
    </footer>
  {/if}
</article>

<style>
  .note {
    display: flex;
    flex-direction: column;
    width: 100%;
    min-height: 0;
    padding: 6px 10px 8px;
    color: var(--text);
    font-size: 13px;
    background: var(--surface);
    border-radius: 12px;
    box-shadow: var(--shadow-raised);
    transition: opacity 200ms ease;
  }
  .note.selected {
    box-shadow: 0 0 0 2px var(--focus-ring), var(--shadow-raised);
  }
  .note.loose {
    background: color-mix(in oklab, var(--surface), var(--accent) 6%);
  }
  /* A sent note steps back but stays readable over whatever it sits on. */
  .note.sent {
    color: var(--muted);
    background: var(--title-bar);
    box-shadow: var(--shadow);
  }
  header {
    display: flex;
    align-items: center;
    gap: 6px;
    min-width: 0;
    margin: 0 -4px 2px;
    cursor: grab;
  }
  .about {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    color: var(--muted);
    font-size: 11px;
    white-space: nowrap;
    text-overflow: ellipsis;
  }
  header button {
    display: grid;
    place-items: center;
    width: 22px;
    height: 22px;
    padding: 0;
    color: var(--muted);
    background: none;
    border: 0;
    border-radius: 6px;
    cursor: pointer;
  }
  header button:hover {
    color: var(--text);
    background: var(--hover);
  }
  .grip {
    color: var(--accent) !important;
    cursor: crosshair !important;
  }
  textarea {
    width: 100%;
    min-height: 44px;
    max-height: 320px;
    padding: 2px 0;
    color: var(--text);
    font: inherit;
    line-height: 1.45;
    background: none;
    border: 0;
    outline: 0;
    resize: none;
    field-sizing: content;
    cursor: text;
  }
  footer {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-top: 4px;
  }
  .spacer {
    flex: 1;
  }
  .state {
    color: var(--muted);
    font-size: 11.5px;
  }
  .problem {
    color: var(--danger);
    font-size: 11.5px;
  }
  .send {
    height: 24px;
    padding: 0 10px;
    color: var(--surface);
    font: inherit;
    font-size: 12px;
    font-weight: 560;
    background: var(--accent);
    border: 0;
    border-radius: 7px;
    cursor: pointer;
  }
  .send:disabled {
    opacity: 0.35;
    cursor: default;
  }
</style>
