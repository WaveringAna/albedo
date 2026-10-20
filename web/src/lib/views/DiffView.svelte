<script lang="ts">
  import { FileDiff, processFile, type SelectedLineRange } from '@pierre/diffs';
  import { untrack } from 'svelte';
  import { diffs } from '../anchors';
  import { prefs } from '../prefs.svelte';

  // One file's diff, highlighted by @pierre/diffs (Shiki underneath). Notes
  // about its lines live on the canvas, not in the file: the diff only says
  // which diff it is (`key`, for notes to find their lines) and asks
  // `oncomment` to start one when the margin's button picks lines.
  let {
    key,
    path,
    change,
    diff,
    oncomment,
  }: {
    key: string;
    path: string;
    change: number;
    diff: string;
    oncomment?: (range: SelectedLineRange) => void;
  } = $props();

  let container = $state<HTMLElement>();
  let view = $state.raw<FileDiff>();

  $effect(() => {
    diffs.set(key, { path, change, diff });
    return () => diffs.delete(key);
  });

  // A trace's diff may lack git's file headers; give it some so the
  // language is known from the name.
  const parsed = $derived(processFile(/^(---|diff )/m.test(diff) ? diff : `--- a/${path}\n+++ b/${path}\n${diff}`, { cacheKey: `${path}:${diff.length}:${hash(diff)}` }));

  $effect(() => {
    if (!container) return;
    const created = new FileDiff({
      theme: { dark: 'pierre-dark', light: 'pierre-light' },
      themeType: untrack(() => prefs.resolved),
      diffStyle: 'unified',
      overflow: 'scroll',
      disableFileHeader: true,
      hunkSeparators: 'line-info',
      lineDiffType: 'word',
      enableGutterUtility: !!oncomment,
      // A finished pick must not stay selected: the margin button keeps to a
      // standing selection, so the next comment would land on the old lines.
      onGutterUtilityClick: (range) => {
        oncomment?.(range);
        setTimeout(() => created.setSelectedLines(null));
      },
      // The canvas's own ground and diff colours, under Pierre's token colours.
      unsafeCSS: `:host {
        --diffs-light-bg: var(--well) !important;
        --diffs-dark-bg: var(--well) !important;
        --diffs-addition-color-override: var(--added);
        --diffs-deletion-color-override: var(--danger);
        --diffs-selection-color-override: var(--accent);
        --diffs-bg-addition-override: color-mix(in oklab, var(--added) 8%, var(--well));
        --diffs-bg-addition-number-override: color-mix(in oklab, var(--added) 12%, var(--well));
        --diffs-bg-addition-emphasis-override: color-mix(in oklab, var(--added) 20%, var(--well));
        --diffs-bg-deletion-override: color-mix(in oklab, var(--danger) 8%, var(--well));
        --diffs-bg-deletion-number-override: color-mix(in oklab, var(--danger) 12%, var(--well));
        --diffs-bg-deletion-emphasis-override: color-mix(in oklab, var(--danger) 20%, var(--well));
        --diffs-font-family: var(--mono);
        --diffs-font-size: 12px;
        --diffs-line-height: 19px;
      }`,
    });
    view = created;
    return () => {
      created.cleanUp();
      view = undefined;
    };
  });

  $effect(() => {
    view?.setThemeType(prefs.resolved);
  });

  $effect(() => {
    if (!view || !container || !parsed) return;
    view.render({ fileDiff: parsed, containerWrapper: container });
  });

  function hash(text: string) {
    let h = 0;
    for (let i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) | 0;
    return h >>> 0;
  }
</script>

<div class="diff" data-diff={key} bind:this={container}></div>

<style>
  .diff {
    overflow: hidden;
    border-radius: 10px;
  }
</style>
