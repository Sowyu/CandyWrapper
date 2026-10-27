// Capture-only markup: MarkdownMath.tsx:17-57 and MathTypeset.tsx:17-25,39.
const fs = require('node:fs');
const path = require('node:path');
const home = require('node:os').homedir();
const katex = require(path.join(home, 'CandyWrapper-research/tools/katex-0.16.47/node_modules/katex'));
if (katex.version !== '0.16.47') throw Error(`Unexpected KaTeX ${katex.version}`);
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
function math(tex, display) {
  tex = tex.trim();
  const source = display ? `\\[\n${tex}\n\\]` : `\\(${tex}\\)`;
  let rendered;
  try { rendered = `<span>${katex.renderToString(tex, {displayMode: display, output:'htmlAndMathml', throwOnError:true, trust:false, strict:'ignore', maxSize:20, maxExpand:1000})}</span>`; }
  catch (error) {
    if (tex !== String.raw`\frac{a}{`) throw error;
    rendered = `<span class="whitespace-pre-wrap">${escape(source)}</span>`;
  }
  const outer = display ? 'chat-markdown-math-display my-[0.65rem] block in-[.chat-markdown-table-container]:max-w-none in-[.chat-markdown-table-container]:overflow-visible' : 'inline-block max-w-full align-middle whitespace-nowrap wrap-normal break-normal in-[.chat-markdown-table-container]:max-w-none in-[.chat-markdown-table-container]:overflow-visible';
  const scroll = 'block max-w-full overflow-x-auto overflow-y-hidden in-[.chat-markdown-table-container]:max-w-none in-[.chat-markdown-table-container]:overflow-visible px-0.5 py-0.75 focus-visible:outline-1 focus-visible:outline-solid focus-visible:-outline-offset-1 focus-visible:outline-border [&::-webkit-scrollbar]:h-2 [&::-webkit-scrollbar-thumb]:rounded [&::-webkit-scrollbar-thumb]:border [&::-webkit-scrollbar-thumb]:border-transparent [&::-webkit-scrollbar-thumb]:bg-clip-content';
  return `<span class="${outer}" data-markdown-math="${display ? 'display':'inline'}" data-markdown-copy="${escape(source + (display ? '\n\n':''))}" role="group" aria-label="${display ? 'Display':'Inline'} equation"><span class="${scroll}" tabindex="0" aria-label="Scroll ${display ? 'display':'inline'} equation"><span class="inline-block w-max${display ? ' min-w-full':''}">${rendered}</span></span></span>`;
}
// ChatMarkdown.tsx:1591-1593 supplies the body typography around the wrapper.
const markdownClass = 'chat-markdown w-full min-w-0 [overflow-wrap:anywhere] [word-break:break-word] text-sm leading-relaxed text-foreground/[calc(80%+var(--appearance-contrast-boost)/5)]';
const cases = corpus.map(([name, display, tex], i) => ({name:`${String(i+1).padStart(2,'0')}-${name}`, tex, display:!!display, html:`<div class="${markdownClass}" style="font-size:14px;${display ? 'width:480px':'display:inline-block'}">${math(tex, !!display)}</div>`}));
for (const [name, before, tex, after] of [
  ['paragraph-energy','Energy is ',String.raw`E = mc^2`,' here.'],
  ['paragraph-fraction','The ratio ',String.raw`\frac{a}{b}`,' grows.'],
  ['paragraph-sum','Sum ',String.raw`\sum_{i=1}^{n} x_i`,' ends.'],
]) cases.push({name:`${cases.length+1}-${name}`, tex, display:false, paragraph:true, html:`<div class="${markdownClass}" style="font-size:14px;width:480px"><p>${before}${math(tex,false)}${after}</p></div>`});
cases.push({name:'39-fallback', tex:String.raw`\frac{a}{`, display:false, html:`<div class="${markdownClass}" style="font-size:14px;display:inline-block">${math(String.raw`\frac{a}{`,false)}</div>`});
const spec = {component:'math', source:'apps/web/src/components/chat/MarkdownMath.tsx:17-57; MathTypeset.tsx:17-25,39; ChatMarkdown.tsx:1591-1593', katexVersion:katex.version, states:['rest'], themes:['light','dark'], scales:[1,2], stylesheets:['~/CandyWrapper-research/tools/katex-0.16.47/node_modules/katex/dist/katex.min.css'], measure:fs.readFileSync('scripts/math-reference-metrics.js','utf8').trim(), cases};
fs.writeFileSync('design/component-reference/math.json', JSON.stringify(spec,null,2)+'\n');
