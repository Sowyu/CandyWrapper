// Capture-only markup for T3 5258: Words renders each formula as SVG (apps/web/src/markdown/wordsHast.ts:323-369
// sanitizeMath, :858-892 mathWrapper, :1146-1152 options) and index.css:2348-2355 sizes it.
const fs = require('node:fs');
const path = require('node:path');
const home = require('node:os').homedir();
const wordsDir = path.join(home, 'CandyWrapper-research/tools/pierre-words-0.2.2-t3.4/package');
const wordsVersion = JSON.parse(fs.readFileSync(path.join(wordsDir, 'package.json'), 'utf8')).version;
if (wordsVersion !== '0.2.2-t3.4') throw Error(`Unexpected Words ${wordsVersion}`);
const corpus = [
['power',0,String.raw`x^2`],
['scripts',0,String.raw`x_i^2`],
['inline-fraction',0,String.raw`\frac{a}{b}`],
['display-fraction',1,String.raw`\frac{a+b}{c-d}`],
['square-root',0,String.raw`\sqrt{x}`],
['cube-root',1,String.raw`\sqrt[3]{x+1}`],
['greek',0,String.raw`\alpha + \beta = \gamma`],
['gamma',0,String.raw`\Gamma(n) = (n-1)!`],
['display-sum',1,String.raw`\sum_{i=1}^{n} i = \frac{n(n+1)}{2}`],
['inline-sum',0,String.raw`\sum_{i=1}^{n} x_i`],
['gaussian-integral',1,String.raw`\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}`],
['inline-integral',0,String.raw`\int_a^b f(x)\,dx`],
['product',1,String.raw`\prod_{k=1}^{n} k`],
['limit',1,String.raw`\lim_{x \to 0} \frac{\sin x}{x} = 1`],
['energy',0,String.raw`E = mc^2`],
['relations',0,String.raw`a \le b \neq c \approx d`],
['delimiters',1,String.raw`\left( \frac{a}{b} \right)^2`],
['matrix',1,String.raw`\begin{pmatrix} a & b \\ c & d \end{pmatrix}`],
['identity-matrix',1,String.raw`\begin{bmatrix} 1 & 0 & 0 \\ 0 & 1 & 0 \\ 0 & 0 & 1 \end{bmatrix}`],
['cases',1,String.raw`f(x) = \begin{cases} x & x \ge 0 \\ -x & x < 0 \end{cases}`],
['aligned',1,String.raw`\begin{aligned} a &= b + c \\ d &= e \end{aligned}`],
['text',0,String.raw`\text{if } x > 0 \text{ then } y`],
['accents',0,String.raw`\hat{x} + \bar{y} + \vec{v} + \tilde{n} + \dot{a}`],
['blackboard',0,String.raw`\mathbb{R}^n \to \mathbb{R}`],
['bold',0,String.raw`\mathbf{v} \cdot \mathbf{w} = 0`],
['quantifiers',0,String.raw`\forall \epsilon > 0, \exists \delta > 0`],
['binomial',1,String.raw`\binom{n}{k} = \frac{n!}{k!(n-k)!}`],
['spacing',0,String.raw`a\,b\;c\quad d\qquad e`],
['divergence',1,String.raw`\nabla \cdot \mathbf{E} = \frac{\rho}{\varepsilon_0}`],
['quadratic',1,String.raw`x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}`],
['overline',0,String.raw`\overline{AB} \perp \mathcal{L}`],
['norm',0,String.raw`\| x \|_2 = \sqrt{\sum_i x_i^2}`],
['determinant',0,String.raw`\det(A - \lambda I) = 0`],
['euler',1,String.raw`e^{i\pi} + 1 = 0`],
['set',0,String.raw`\{ x \in \mathbb{Z} : x \bmod 2 = 0 \}`],
];
const escape = s => s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
// sanitizeMath's elements, attributes (as HTML names) and style properties.
const elements = new Set(['svg','g','text','tspan','rect','path']);
const attributes = new Set(['xmlns','width','height','viewBox','fill','font-family','font-size','font-style','font-weight','role','aria-label','x','y','dx','dy','d','transform','stroke','stroke-width','text-anchor']);
const styleKeep = /^(?:display|vertical-align|overflow|margin|white-space)$/;
function sanitize(svg) {
  return svg.replace(/<(\/?)([a-zA-Z]+)((?:\s+[a-zA-Z-:]+="[^"]*")*)\s*(\/?)>/g, (all, close, tag, attrs, self) => {
    if (!elements.has(tag)) throw Error(`Words emitted <${tag}>`);
    if (close) return `</${tag}>`;
    const kept = [...attrs.matchAll(/([a-zA-Z-:]+)="([^"]*)"/g)].flatMap(([, k, v]) => {
      if (k === 'style') { const st = v.split(';').filter(r => styleKeep.test(r.split(':')[0].trim())).join(';'); return st ? [`style="${st}"`] : []; }
      return attributes.has(k) ? [`${k}="${v}"`] : [];
    });
    return `<${tag}${kept.map(a => ' ' + a).join('')}${self ? '/' : ''}>`;
  });
}
const scroll = 'max-w-full overflow-x-auto overflow-y-hidden px-0.5 py-0.75 in-[.chat-markdown-table-container]:max-w-none in-[.chat-markdown-table-container]:overflow-visible';
let words;
async function math(tex, display) {
  tex = tex.trim();
  const html = new TextDecoder().decode(await words.renderToHtml(display ? `$$${tex}$$` : `$${tex}$`, {math:true, texDelimiters:true}));
  const svgs = html.match(/<svg[\s\S]*?<\/svg>/g);
  if (!svgs || svgs.length !== 1) throw Error(`No single formula for ${tex}: ${html}`);
  const svg = sanitize(svgs[0]);
  // mathWrapper reads the TeX back from the SVG's label, as T3 does.
  const label = svg.match(/aria-label="([^"]*)"/)[1].replaceAll('&quot;','"').replaceAll('&lt;','<').replaceAll('&gt;','>').replaceAll('&amp;','&').trim();
  const isDisplay = /display:\s*block/.test(svg.match(/style="([^"]*)"/)?.[1] ?? '');
  if (isDisplay !== display) throw Error(`Words put ${tex} in the wrong mode`);
  return display
    ? `<span class="chat-markdown-math-display block ${scroll}" data-markdown-math="display" data-markdown-copy="${escape(`\\[\n${label}\n\\]\n\n`)}">${svg}</span>`
    : `<span class="inline-block align-middle ${scroll}" data-markdown-math="inline" data-markdown-copy="${escape(`\\(${label}\\)`)}">${svg}</span>`;
}
// ChatMarkdown.tsx:2105-2112 supplies the body typography around the wrapper.
const markdownClass = 'chat-markdown w-full min-w-0 [overflow-wrap:anywhere] [word-break:break-word] text-sm leading-relaxed text-foreground/[calc(90%+var(--appearance-contrast-boost)/10)]';
(async () => {
  words = await import(path.join(wordsDir, 'dist/index.js'));
  const cases = [];
  for (const [i, [name, display, tex]] of corpus.entries())
    cases.push({name:`${String(i+1).padStart(2,'0')}-${name}`, tex, display:!!display, html:`<div class="${markdownClass}" style="font-size:14px;${display ? 'width:480px':'display:inline-block'}">${await math(tex, !!display)}</div>`});
  for (const [name, before, tex, after] of [
    ['paragraph-energy','Energy is ',String.raw`E = mc^2`,' here.'],
    ['paragraph-fraction','The ratio ',String.raw`\frac{a}{b}`,' grows.'],
    ['paragraph-sum','Sum ',String.raw`\sum_{i=1}^{n} x_i`,' ends.'],
  ]) cases.push({name:`${cases.length+1}-${name}`, tex, display:false, paragraph:true, html:`<div class="${markdownClass}" style="font-size:14px;width:480px"><p>${before}${await math(tex,false)}${after}</p></div>`});
  // Words lays out an unclosed group as if it closed, so 5258 draws this as a fraction with an empty denominator.
  cases.push({name:'39-fallback', tex:String.raw`\frac{a}{`, display:false, html:`<div class="${markdownClass}" style="font-size:14px;display:inline-block">${await math(String.raw`\frac{a}{`,false)}</div>`});
  const spec = {component:'math', source:'apps/web/src/markdown/wordsHast.ts:323-369,858-892,1146-1152; index.css:2348-2355; components/ChatMarkdown.tsx:2105-2112', wordsVersion, states:['rest'], themes:['light','dark'], scales:[1,2], measure:fs.readFileSync('scripts/math-reference-metrics.js','utf8').trim(), cases};
  fs.writeFileSync('design/component-reference/math.json', JSON.stringify(spec,null,2)+'\n');
})();
