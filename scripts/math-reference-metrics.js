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
  const svg = wrapper.querySelector(':scope > svg');
  if (!svg) throw Error('Missing formula SVG');
  // Words' viewBox is in thousandths of the SVG's em, with y = 0 on the baseline.
  const box = svg.getBoundingClientRect(), em = parseFloat(getComputedStyle(svg).fontSize), vb = svg.viewBox.baseVal;
  const y = box.top - vb.y / 1000 * em;
  result.formula = {width:box.width, height:-vb.y / 1000 * em, depth:(vb.height + vb.y) / 1000 * em, em, baselineY:y-clip.y, baselinePixelY:(y-clip.y)*scale};
  if (!Object.values(result.formula).every(Number.isFinite)) throw Error('Invalid formula metrics');
  if (!document.fonts.check(`${em}px "STIX Two Math"`)) throw Error('STIX Two Math is missing');
  const paragraph = root.querySelector('p');
  if (paragraph) {
    result.textBaselineY = baseline(paragraph)-clip.y;
    result.formulaBaselineY = result.formula.baselineY;
  }
  return result;
}
