"""Child approvals in the parent thread (Nightly 4928 #28516): ChildThreadApprovals.tsx:16-95 with
ComposerPendingApprovalActions.tsx:43-141 in its inline presentation and InlineButton (button.tsx:103-139).
Run with python3 -I, then scripts/component-reference design/component-reference/child-approvals.json.
"""
import json, os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

INLINE = ("inline-flex shrink-0 cursor-pointer items-center gap-0.5 font-medium underline-offset-2 "
          "[text-align:var(--inline-button-text-align,center)] [white-space:var(--inline-button-white-space,nowrap)] "
          "hover:underline focus-visible:outline-2 focus-visible:outline-ring disabled:pointer-events-none disabled:opacity-64")
TONE = {"default": "text-foreground", "muted": "text-muted-foreground hover:text-foreground"}

def button(label, tone, disabled):
    return ('<button type="button" data-slot="inline-button" class="' + INLINE + ' ' + TONE[tone] + '"'
            + (' disabled' if disabled else '') + '><span class="whitespace-normal">' + label + '</span></button>')

def card(title, detail, app=None, reason=None, live=True):
    html = '<section class="rounded-lg border border-border bg-background p-3 text-xs">'
    html += '<p class="mb-2 font-medium">Approval needed from ' + title + '</p>'
    html += '<pre class="max-h-40 overflow-auto whitespace-pre-wrap break-words font-mono">' + detail + '</pre>'
    if app: html += '<p class="mt-2 text-muted-foreground">' + app + '</p>'
    if not live: html += '<p class="mt-2 text-warning">Provider process is gone. Interrupt or restart the child thread to respond.</p>'
    if reason: html += '<p class="mt-2 text-muted-foreground">' + reason + '</p>'
    html += '<div class="mt-2 flex flex-wrap gap-2">'
    html += button('Decline', 'muted', not live) + button('Approve', 'default', not live) + button('More', 'muted', not live)
    html += '</div></section>'
    return html

def stack(cards):
    # The list's own `mb-2` sits under the capture, so the wrapper leaves it out.
    return '<div class="flex max-h-80 flex-col gap-2 overflow-auto">' + ''.join(cards) + '</div>'

cases = [
    {'name': 'one', 'html': stack([card('Release notes', 'git push origin main')]),
     'native': {'cards': [{'title': 'Release notes', 'detail': 'git push origin main'}]}},
    {'name': 'two', 'html': stack([
        card('Release notes', 'rm -rf build/ dist/', reason='Clean the old artifacts before the release build.'),
        card('Docs pass', 'git push origin docs', live=False)]),
     'native': {'cards': [{'title': 'Release notes', 'detail': 'rm -rf build/ dist/', 'reason': 'Clean the old artifacts before the release build.'},
                          {'title': 'Docs pass', 'detail': 'git push origin docs', 'live': False}]}},
]
spec = {'component': 'child-approvals', 'source': 'apps/web/src/components/chat/ChildThreadApprovals.tsx',
        'states': ['rest'], 'themes': ['light', 'dark'], 'wrapperStyle': 'display:block;width:480px', 'cases': cases}
for c in cases: c['wrapperStyle'] = 'display:block;width:480px'
with open(os.path.join(ROOT, 'design/component-reference/child-approvals.json'), 'w') as out: json.dump(spec, out, indent=1)
