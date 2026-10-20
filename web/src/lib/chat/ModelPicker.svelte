<script lang="ts">
  import { configureSession, type Session } from '../api';
  import ModelChoice from '../ModelChoice.svelte';
  import { sessions } from '../sessions.svelte';

  // The session's model, as a small chip in the composer; it opens a pane
  // above it to change the provider, model and effort for this session.
  let { session }: { session: Session } = $props();
  let open = $state(false);
  let profile = $state<string | null>(null);
  let model = $state<string | null>(null);
  let effort = $state<string | null>(null);
  let saving = $state(false);
  let problem = $state('');
  let pane = $state<HTMLElement>();

  const changed = $derived(profile !== session.provider_profile || model !== session.model || effort !== session.effort);

  function show() {
    [profile, model, effort, problem] = [session.provider_profile, session.model, session.effort, ''];
    open = !open;
  }

  $effect(() => {
    if (!open) return;
    const away = (event: PointerEvent) => !pane?.contains(event.target as Node) && !(event.target as Element).closest('.model-chip') && (open = false);
    const key = (event: KeyboardEvent) => event.key === 'Escape' && (open = false);
    document.addEventListener('pointerdown', away, true);
    document.addEventListener('keydown', key);
    return () => {
      document.removeEventListener('pointerdown', away, true);
      document.removeEventListener('keydown', key);
    };
  });

  async function apply() {
    saving = true;
    problem = '';
    try {
      await configureSession(session.id, { provider_profile: profile, model, effort });
      await sessions.refresh();
      open = false;
    } catch (error) {
      problem = String((error as Error).message ?? error);
    } finally {
      saving = false;
    }
  }
</script>

<span class="picker">
  <button type="button" class="model-chip" aria-expanded={open} title="model for this session" onclick={show}>
    {session.model ?? 'model'}{#if session.effort}<span class="effort">{session.effort}</span>{/if}
  </button>
  {#if open}
    <div class="pane" bind:this={pane} role="dialog" aria-label="model for this session">
      <ModelChoice bind:profile bind:model bind:effort />
      {#if problem}<p class="problem">{problem}</p>{/if}
      <div class="actions">
        <span class="note">from the next turn on</span>
        <button type="button" class="apply" disabled={!changed || saving} onclick={apply}>{saving ? 'switching…' : 'switch'}</button>
      </div>
    </div>
  {/if}
</span>

<style>
  .picker {
    position: relative;
    min-width: 0;
  }
  .model-chip {
    display: flex;
    align-items: baseline;
    gap: 5px;
    max-width: 100%;
    padding: 3px 8px;
    overflow: hidden;
    color: var(--muted);
    font: inherit;
    font-size: 12px;
    white-space: nowrap;
    text-overflow: ellipsis;
    background: none;
    border: 0;
    border-radius: 8px;
    cursor: pointer;
  }
  .model-chip:hover,
  .model-chip[aria-expanded='true'] {
    color: var(--text);
    background: var(--hover);
  }
  .effort {
    color: var(--faint);
  }
  .pane {
    position: absolute;
    bottom: calc(100% + 10px);
    left: -8px;
    z-index: 10;
    width: min(360px, calc(100vw - 32px));
    padding: 14px;
    background: var(--surface);
    border-radius: 14px;
    box-shadow: var(--shadow-lg);
  }
  .actions {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-top: 12px;
  }
  .note {
    color: var(--faint);
    font-size: 11.5px;
  }
  .apply {
    height: 30px;
    padding: 0 14px;
    color: var(--surface);
    font: inherit;
    font-size: 12.5px;
    font-weight: 560;
    background: var(--accent);
    border: 0;
    border-radius: 8px;
    cursor: pointer;
  }
  .apply:disabled {
    opacity: 0.4;
    cursor: default;
  }
  .problem {
    margin: 8px 0 0;
    color: var(--danger);
    font-size: 12.5px;
  }
</style>
