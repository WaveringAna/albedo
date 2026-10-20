// Draws what renderMarkdown left as placeholders: maths with KaTeX and
// Mermaid diagrams with Pele, each loaded the first time a message needs it.
// A placeholder keeps its source as text, so a failure leaves it readable.

let katex: Promise<typeof import('katex')['default']> | null = null;
let pele: Promise<typeof import('pele/lazy')> | null = null;

function loadKatex() {
  return (katex ??= Promise.all([import('katex'), import('katex/dist/katex.min.css')]).then(([module]) => module.default));
}

function loadPele() {
  return (pele ??= import('pele/lazy'));
}

// Pele draws from text the model wrote; keep only drawing in what it returns.
function clean(svg: string): SVGElement | null {
  const parsed = new DOMParser().parseFromString(svg, 'image/svg+xml').documentElement;
  if (parsed.nodeName.toLowerCase() !== 'svg') return null;
  for (const element of [parsed, ...parsed.querySelectorAll('*')]) {
    if (['script', 'foreignobject', 'iframe'].includes(element.nodeName.toLowerCase())) element.remove();
    for (const attribute of [...element.attributes]) {
      const value = attribute.value.trim().toLowerCase();
      if (attribute.name.startsWith('on') || ((attribute.name === 'href' || attribute.name.endsWith(':href')) && !value.startsWith('#'))) element.removeAttribute(attribute.name);
    }
  }
  return parsed as unknown as SVGElement;
}

export async function enhance(root: HTMLElement) {
  const maths = [...root.querySelectorAll<HTMLElement>('.math[data-tex]:not([data-drawn])')];
  const diagrams = [...root.querySelectorAll<HTMLElement>('.diagram[data-source]:not([data-drawn])')];
  if (maths.length) {
    const render = await loadKatex();
    for (const element of maths) {
      element.dataset.drawn = '1';
      try {
        render.render(element.dataset.tex ?? '', element, { displayMode: element.dataset.display === '1', throwOnError: false, trust: false, output: 'htmlAndMathml' });
      } catch {}
    }
  }
  if (diagrams.length) {
    const { renderAsync } = await loadPele();
    for (const element of diagrams) {
      element.dataset.drawn = '1';
      try {
        const { svg } = await renderAsync(element.dataset.source ?? '');
        const drawn = clean(svg);
        if (drawn) element.replaceChildren(drawn);
      } catch {}
    }
  }
}
