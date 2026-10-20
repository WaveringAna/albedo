<script lang="ts">
  // What has become of your newest message, drawn as Signal does: a dashed
  // ring while it travels, a ring with a check once the daemon has it, and
  // two filled ones once it is in the model's context.
  let { state }: { state: 'sending' | 'sent' | 'seen' } = $props();
  const tick = (cx: number) => `M${cx - 2.8} 5.6l2 2 3.1-3.3`;
</script>

<svg class="receipt" viewBox="0 0 17.5 12" width="17.5" height="12" role="img" aria-label={state}>
  <title>{state}</title>
  <!-- Every circle is 11 across with the same check, so the states differ only in fill and count. -->
  {#if state === 'seen'}
    <circle cx="5.5" cy="6" r="5.5" class="dot" />
    <path d={tick(5.5)} class="check on" />
    <circle cx="12" cy="6" r="6.2" class="gap" />
    <circle cx="12" cy="6" r="5.5" class="dot" />
    <path d={tick(12)} class="check on" />
  {:else}
    <circle cx="12" cy="6" r="4.9" class="ring" stroke-dasharray={state === 'sending' ? '2.2 1.65' : undefined} />
    {#if state === 'sent'}<path d={tick(12)} class="check" />{/if}
  {/if}
</svg>

<style>
  .receipt {
    overflow: visible;
    margin-right: 2px;
    color: var(--muted);
  }
  .ring {
    fill: none;
    stroke: currentColor;
    stroke-width: 1.2;
  }
  .dot {
    fill: currentColor;
  }
  /* The ground behind the front disc, so the two read as separate. */
  .gap {
    fill: var(--surface);
  }
  .check {
    fill: none;
    stroke: currentColor;
    stroke-width: 1.3;
    stroke-linecap: round;
    stroke-linejoin: miter;
  }
  .check.on {
    stroke: var(--surface);
  }
</style>
