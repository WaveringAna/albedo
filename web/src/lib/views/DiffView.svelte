<script lang="ts" generics="Note">
  import { FileDiff, processFile, type DiffLineAnnotation, type SelectedLineRange } from '@pierre/diffs';
  import { untrack } from 'svelte';
  import { prefs } from '../prefs.svelte';

  // One file's diff, highlighted by @pierre/diffs (Shiki underneath). Notes
  // do not open the file up: each is a bare anchor under its lines, made by
  // `anchor`, and whoever owns the diff draws the note itself elsewhere. The
  // margin's button asks `oncomment` to start one on the lines it covers.
  let {
    path,
    diff,
    notes = [],
    anchor,
    oncomment,
    onrender,
  }: {
    path: string;
    diff: string;
    notes?: DiffLineAnnotation<Note>[];
    anchor: (annotation: DiffLineAnnotation<Note>) => HTMLElement;
    oncomment?: (range: SelectedLineRange) => void;
    onrender?: () => void;
  } = $props();

  let container = $state<HTMLElement>();
  let view = $state.raw<FileDiff<Note>>();

  // A trace's diff may lack git's file headers; give it some so the
  // language is known from the name.
  const parsed = $derived(processFile(/^(---|diff )/m.test(diff) ? diff : `--- a/${path}\n+++ b/${path}\n${diff}`, { cacheKey: `${path}:${diff.length}:${hash(diff)}` }));

  $effect(() => {
    if (!container) return;
    const created = new FileDiff<Note>({
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
      renderAnnotation: (annotation) => anchor(annotation),
      onPostRender: () => onrender?.(),
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
        --diffs-annotation-min-height: 0px;
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
    view.render({ fileDiff: parsed, containerWrapper: container, lineAnnotations: notes });
  });

  function hash(text: string) {
    let h = 0;
    for (let i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) | 0;
    return h >>> 0;
  }
</script>

<div class="diff" bind:this={container}></div>

<style>
  .diff {
    overflow: hidden;
    border-radius: 10px;
  }
</style>
