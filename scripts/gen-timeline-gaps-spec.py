"""Writes design/component-reference/timeline-gaps.json for scripts/component-reference: the surfaces the timeline
task added (partials items 4, 5, 17, 18 and 19).

- The plan's Save to workspace dialog (ProposedPlanCard.tsx:244-283) and the Implement split with its chevron
  (ComposerPrimaryActions.tsx:225-258).
- The citation comment editor in its popover (AssistantCitationCommentEditor.tsx:35-101, AssistantCitationChip.tsx:194-205).
- The item inspector's rich blocks (V2ItemInspector.tsx:180-424): a file change with its changes list, web search
  results, a dynamic tool's arguments and output, a checkpoint with Roll back, and a fork.
- AttachmentFilePreview's header (AttachmentFilePreview.tsx:284-349), in the draft dialog and inline in the right panel.

Markup reuses gen-overlays-spec.py (dialog), gen-files-spec.py (buttons, toggles, lucide), gen-forms-spec.py (input)
and gen-popups-spec.py (popover classes).
Usage: /usr/bin/python3 -I scripts/gen-timeline-gaps-spec.py
"""
import html, json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def load(name, until, extra=None):
    path = os.path.join(ROOT, "scripts", name)
    src = open(path).read()
    ns = {"__file__": path}
    if extra: ns.update(extra)
    exec(src[:src.index(until)], ns)
    return ns

ov = load("gen-overlays-spec.py", 'specs["dialog"] =')
fs = load("gen-files-spec.py", "# T3's sprite")
fm = load("gen-forms-spec.py", "W240 =")
pp = load("gen-popups-spec.py", "# Presets")
pp2 = load("gen-popups-spec.py", "def popover(")
btn, button, toggle, lucide, input_html = ov["btn"], fs["button"], fs["toggle"], fs["lucide"], fm["input_html"]

cases = []

# ------------------------------------------------------------------------------------------- Plan

POPUP = ov["POPUP"].replace("max-w-lg", "max-w-xl")
save_dialog = (f'<div role="dialog" data-slot="dialog-popup" class="{POPUP}">'
               '<div class="flex flex-col gap-2 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-panel])]:pb-3 max-sm:pb-4" data-slot="dialog-header">'
               '<h2 class="wrap-anywhere font-semibold text-xl leading-none" data-slot="dialog-title">Save plan to workspace</h2>'
               '<p class="text-muted-foreground text-sm" data-slot="dialog-description">Enter a path relative to /tmp/demo-repo.</p></div>'
               '<div class="space-y-4 p-6 in-[[data-slot=dialog-popup]:has([data-slot=dialog-header])]:pt-1 in-[[data-slot=dialog-popup]:has([data-slot=dialog-footer]:not(.border-t))]:pb-1" data-slot="dialog-panel">'
               '<label class="grid gap-1.5"><span class="text-xs font-medium text-foreground">Workspace path</span>'
               + input_html(value="fix-login-redirect.md") + '</label></div>'
               '<div class="flex flex-col-reverse gap-2 px-6 sm:flex-row sm:justify-end sm:rounded-b-[calc(var(--radius-2xl)-1px)] border-t bg-muted/72 py-4" data-slot="dialog-footer">'
               + btn("outline", "sm", "Cancel") + btn("default", "sm", "Save") + '</div>' + ov["CLOSE"] + '</div>')
cases.append({"name": "plan.save-dialog", "html": save_dialog, "wrapperStyle": "display:grid;width:576px;margin-bottom:96px",
              "native": {"kind": "save-dialog"}})

PILL = ("inline-flex shrink-0 cursor-pointer items-center justify-center gap-1.5 whitespace-nowrap rounded-full bg-message-action "
        "font-medium text-base text-message-action-foreground shadow-xs shadow-message-action/24 outline-none hover:bg-message-action-hover "
        "focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 focus-visible:ring-offset-background disabled:pointer-events-none "
        "disabled:opacity-64 disabled:shadow-none sm:text-sm")
split = ('<div data-chat-composer-implement-actions="true" class="flex items-center justify-end">'
         f'<button type="submit" class="{PILL} h-9 rounded-r-none px-4 sm:h-8">Implement</button>'
         f'<button type="button" aria-label="Implementation actions" class="{PILL} h-9 rounded-l-none border-l border-message-action-foreground/20 px-2 sm:h-8">'
         + lucide("chevron-down", "size-3.5") + '</button></div>')
# On the composer glass Chromium draws the label unsmoothed: a composited, non-opaque layer does the same here.
GLASS_LAYER = "display:inline-block;will-change:transform"
cases.append({"name": "plan.implement-split", "html": split, "wrapperStyle": GLASS_LAYER, "native": {"kind": "implement-split"}})
cases.append({"name": "plan.refine", "html": f'<button type="submit" class="{PILL} h-9 sm:h-8 px-4">Refine</button>', "wrapperStyle": GLASS_LAYER, "native": {"kind": "refine"}})

# ---------------------------------------------------------------------------------- Citation comment

P_BASE, P_VIEWPORT, P_PAD, P_WIDTH = pp2["P_BASE"], pp2["P_VIEWPORT"], pp2["P_PAD"], pp2["P_WIDTH"]
TEXTAREA = ("field-sizing-content block max-h-40 min-h-16 w-full resize-none bg-transparent px-1 py-1.5 text-base outline-none "
            "placeholder:text-muted-foreground sm:text-sm")
def comment_editor(value):
    return (f'<div class="{P_BASE} {P_WIDTH["md"]}" data-slot="popover-popup" data-side="bottom">'
            f'<div class="{P_VIEWPORT} {P_PAD["compact"]} not-data-transitioning:overflow-y-auto" data-slot="popover-viewport">'
            '<div data-citation-comment-editor="true">'
            f'<textarea aria-label="Comment on selected text" placeholder="Add an optional comment..." rows="2" class="{TEXTAREA}">{html.escape(value)}</textarea>'
            '<div class="mt-2 flex items-center justify-end gap-2">' + btn("outline", "xs", "Cancel") + btn("default", "xs", "Save") + '</div>'
            '</div></div></div>')
cases.append({"name": "citation.empty", "html": comment_editor(""), "wrapperStyle": "display:inline-block;--available-height:600px;margin-bottom:64px",
              "native": {"kind": "citation", "comment": ""}})
cases.append({"name": "citation.comment", "html": comment_editor("Why does this skip the cache?"),
              "wrapperStyle": "display:inline-block;--available-height:600px;margin-bottom:64px", "native": {"kind": "citation", "comment": "Why does this skip the cache?"}})

# ------------------------------------------------------------------------------------------- Inspector

MONO = "font-mono text-(length:--font-size-code,var(--text-2xs)) leading-relaxed whitespace-pre-wrap break-words select-text"
def inspector(body):
    return f'<div class="space-y-2 text-xs" data-v2-item-inspector="x">{body}</div>'
INSPECTOR_WRAP = "display:block;width:420px;--font-size-code:13px"

file_change = inspector(
    '<div class="space-y-2"><div class="flex flex-wrap items-center gap-2">'
    '<span class="font-mono text-muted-foreground">demo-repo/Sources/Login.swift</span>'
    '<span><span class="text-success">+12</span> <span class="text-destructive">-3</span></span>'
    + btn("outline", "xs", "Open diff") + '</div>'
    '<ul class="space-y-1 font-mono text-muted-foreground"><li>update demo-repo/Sources/Login.swift</li>'
    '<li>rename Sources/Old.swift → demo-repo/Sources/Session.swift (swift, text/x-swift)</li></ul></div>')
cases.append({"name": "inspector.file-change", "html": file_change, "wrapperStyle": INSPECTOR_WRAP, "native": {"kind": "inspector", "item": "file-change"}})

web = inspector(
    f'<div class="text-foreground/85 {MONO}">swift async let</div>'
    '<ul class="space-y-1.5"><li><a href="#" class="inline-flex items-center gap-1 font-medium text-foreground hover:underline">'
    'Concurrency | Swift.org' + lucide("external-link", "size-3") + '</a>'
    '<p class="text-muted-foreground">Use async let to run child tasks in parallel.</p></li>'
    '<li><p class="font-medium text-foreground">Search result</p></li></ul>')
cases.append({"name": "inspector.web-search", "html": web, "wrapperStyle": INSPECTOR_WRAP, "native": {"kind": "inspector", "item": "web-search"}})

tool = inspector(
    f'<div class="space-y-1.5 {MONO}"><div class="text-foreground/85"><div><span class="text-muted-foreground">path </span>README.md</div>'
    '<div><span class="text-muted-foreground">limit </span>40</div></div>'
    '<div class="max-h-80 overflow-auto text-muted-foreground"># Demo repo</div></div>')
cases.append({"name": "inspector.dynamic-tool", "html": tool, "wrapperStyle": INSPECTOR_WRAP, "native": {"kind": "inspector", "item": "dynamic-tool"}})

checkpoint = inspector('<div class="flex flex-wrap items-center gap-2"><span class="text-muted-foreground">ready · 3 files</span>'
                       + btn("outline", "xs", lucide("rotate-ccw", "size-3") + "Roll back") + '</div>')
cases.append({"name": "inspector.checkpoint", "html": checkpoint, "wrapperStyle": INSPECTOR_WRAP, "native": {"kind": "inspector", "item": "checkpoint"}})

fork = inspector(btn("outline", "xs", lucide("git-branch", "size-3") + "Open fork"))
cases.append({"name": "inspector.fork", "html": fork, "wrapperStyle": INSPECTOR_WRAP, "native": {"kind": "inspector", "item": "fork"}})

# ------------------------------------------------------------------------------------ Attachment preview

SUB = fs["SUB"] if "SUB" in fs else ("flex h-10 min-h-10 shrink-0 items-center gap-2 border-b border-border/60 bg-background px-3 "
      "in-data-[preview-panel-mode=inline]:mb-3 in-data-[preview-panel-mode=inline]:h-7 in-data-[preview-panel-mode=inline]:min-h-7 "
      "in-data-[preview-panel-mode=inline]:border-b-transparent")
def action(icon, label):
    return button("ghost", "icon-sm", lucide(icon, "size-3.5"), "shrink-0", label)
def header(origin, name, size, actions, inline):
    mode = ' data-preview-panel-mode="inline"' if inline else ""
    return (f'<div{mode} style="width:560px" class="flex flex-col bg-background"><div class="flex min-h-0 flex-1 flex-col overflow-hidden bg-background">'
            f'<div class="{SUB}" data-surface-subheader><div class="flex min-w-0 flex-1 items-center text-xs">'
            f'<span class="shrink-0 px-0.5 text-muted-foreground">{origin}</span>'
            + lucide("chevron-right", "mx-1 size-3.5 shrink-0 text-muted-foreground/60")
            + f'<span aria-current="page" class="min-w-0 truncate px-0.5 font-medium text-foreground">{name}</span>'
            f'<span class="ml-2 shrink-0 text-muted-foreground">{size}</span></div>' + "".join(actions) + '</div></div></div>')
draft = header("Draft", "notes.md", "2 KB", [toggle(lucide("code-xml", "size-3.5"), True), action("copy", "Copy contents"),
                                            action("download", "Save file"), action("trash-2", "Remove from draft"), action("x", "Close")], False)
cases.append({"name": "attachment.draft", "html": draft, "wrapperStyle": "display:block;width:560px", "native": {"kind": "attachment", "variant": "draft"}})
sent = header("Attachment", "report.ts", "12 KB", [toggle(lucide("wrap-text", "size-3.5"), True), action("copy", "Copy contents"),
                                                   action("download", "Save file")], True)
cases.append({"name": "attachment.sent", "html": sent, "wrapperStyle": "display:block;width:560px", "native": {"kind": "attachment", "variant": "sent"}})

spec = {"component": "timeline-gaps",
        "source": "chat/ProposedPlanCard.tsx; chat/ComposerPrimaryActions.tsx; chat/AssistantCitationCommentEditor.tsx; chat/V2ItemInspector.tsx; files/AttachmentFilePreview.tsx",
        "states": ["rest"], "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/timeline-gaps.json"), "w") as fh:
    json.dump(spec, fh, indent=1, ensure_ascii=False)
print(f"wrote {len(cases)} cases")
