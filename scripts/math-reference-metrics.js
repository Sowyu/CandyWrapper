(index, clip, scale) => {
  const root = document.querySelectorAll('.case > div > :first-child')[index];
  const wrapper = root.querySelector('[data-markdown-math]');
  const rect = wrapper.getBoundingClientRect();
  // A zero-area inline-block's top is its baseline. Remove probes before returning.
  const baseline = element => {
    const probe = document.createElement('span');
    probe.style.cssText = 'display:inline-block;width:0;height:0;padding:0;margin:0;border:0;vertical-align:baseline';
    element.append(probe);
    const y = probe.getBoundingClientRect().top;
    probe.remove();
    return y;
  };
  const result = {scale, units:'CSS px', wrapper:{width:rect.width,height:rect.height}, capture:{x:clip.x,y:clip.y,width:clip.width,height:clip.height}, background:getComputedStyle(document.body).backgroundColor};
  const html = wrapper.querySelector('.katex-html');
  if (html) {
    const y = baseline(html);
    // Each top-level KaTeX base has a strut that encodes its TeX height and depth.
    // Include the separate tag strut if a future corpus includes an equation tag.
    const struts = [...html.querySelectorAll(':scope > .base > .strut, :scope > .tag > .strut')];
    if (!struts.length) throw Error('Missing KaTeX struts');
    const dimensions = struts.map(s => {
      const css = getComputedStyle(s);
      const depth = -(parseFloat(css.verticalAlign) || 0);
      return {height:parseFloat(css.height)-depth,depth};
    });
    const bases = [...html.querySelectorAll(':scope > .base')].map(b => b.getBoundingClientRect());
    const contentWidth = Math.max(...bases.map(b=>b.right))-Math.min(...bases.map(b=>b.left));
    const fonts = [...document.fonts].filter(f => f.status === 'loaded' && f.family.startsWith('KaTeX_')).map(f => `${f.family}:${f.style}:${f.weight}`).sort();
    if (!fonts.length) throw Error('KaTeX fonts did not load');
    result.formula = {width:html.getBoundingClientRect().width, contentWidth, height:Math.max(...dimensions.map(d=>d.height)), depth:Math.max(...dimensions.map(d=>d.depth)), baselineY:y-clip.y, baselinePixelY:(y-clip.y)*scale};
    if (!Object.values(result.formula).every(Number.isFinite)) throw Error('Invalid formula metrics');
    result.loadedKatexFonts = fonts;
  } else {
    result.fallbackBaselineY = baseline(wrapper.querySelector('.whitespace-pre-wrap'))-clip.y;
  }
  const paragraph = root.querySelector('p');
  if (paragraph) {
    result.textBaselineY = baseline(paragraph)-clip.y;
    result.formulaBaselineY = result.formula.baselineY;
  }
  return result;
}
