<script lang="ts">
  import { models, profiles, type Model, type Profile } from './api';

  // The provider profile, model and effort, as a new session and the model
  // picker both choose them. A provider brings its own model list; changing
  // it starts on its own model and effort.
  let {
    profile = $bindable(),
    model = $bindable(),
    effort = $bindable(),
  }: { profile: string | null; model: string | null; effort: string | null } = $props();

  let all = $state<Profile[]>([]);
  let catalogue = $state<Model[]>([]);
  let problem = $state('');
  // svelte-ignore state_referenced_locally
  let shownFor = profile;

  const efforts = $derived(catalogue.find((candidate) => candidate.id === model)?.efforts ?? []);

  $effect(() => {
    profiles()
      .then((found) => {
        all = found.profiles;
        profile ??= found.fallback ?? found.profiles[0]?.id ?? null;
      })
      .catch((error) => (problem = String(error.message ?? error)));
  });

  $effect(() => {
    const id = profile;
    if (!id) return;
    const chosen = all.find((candidate) => candidate.id === id);
    // Only a change of provider resets the model; the first one keeps what was given.
    if (shownFor !== id && chosen) {
      model = chosen.model;
      effort = chosen.effort;
    }
    shownFor = id;
    models(id)
      .then((found) => {
        if (profile !== id) return;
        catalogue = found;
        if (!model || !found.some((candidate) => candidate.id === model)) model = found[0]?.id ?? model;
      })
      .catch(() => (catalogue = []));
  });
</script>

<div class="choices">
  <label>
    <span>provider</span>
    <select bind:value={profile}>
      {#if profile && !all.some((candidate) => candidate.id === profile)}<option value={profile}>{profile}</option>{/if}
      {#each all as candidate (candidate.id)}<option value={candidate.id}>{candidate.id}</option>{/each}
    </select>
  </label>
  <label>
    <span>model</span>
    <select bind:value={model}>
      {#if model && !catalogue.some((candidate) => candidate.id === model)}<option value={model}>{model}</option>{/if}
      {#each catalogue as candidate (candidate.id)}<option value={candidate.id}>{candidate.label}</option>{/each}
    </select>
  </label>
</div>
{#if efforts.length}
  <div class="efforts" role="radiogroup" aria-label="effort">
    {#each efforts as option (option.id)}
      <button type="button" role="radio" aria-checked={effort === option.id} onclick={() => (effort = option.id)}>{option.label}</button>
    {/each}
  </div>
{/if}
{#if problem}<p class="problem">{problem}</p>{/if}

<style>
  .choices {
    display: grid;
    grid-template-columns: 1fr 1.6fr;
    gap: 8px;
  }
  label {
    display: grid;
    gap: 4px;
    color: var(--faint);
    font-size: 11.5px;
  }
  select {
    width: 100%;
    height: 34px;
    padding: 0 10px;
    color: var(--text);
    font: inherit;
    font-size: 13.5px;
    background: var(--field);
    border: 0;
    border-radius: 9px;
    outline: 0;
  }
  select:focus-visible {
    box-shadow: 0 0 0 2px var(--focus-ring);
  }
  .efforts {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    margin-top: 10px;
  }
  .efforts button {
    padding: 4px 10px;
    color: var(--text);
    font: inherit;
    font-size: 12.5px;
    background: var(--field);
    border: 0;
    border-radius: 999px;
    cursor: pointer;
  }
  .efforts [aria-checked='true'] {
    color: var(--surface);
    background: var(--accent);
  }
  .problem {
    margin: 8px 0 0;
    color: var(--danger);
    font-size: 12.5px;
  }
</style>
