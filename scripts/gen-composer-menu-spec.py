"""Writes design/component-reference/composer-menu.json for scripts/component-reference: the composer's
`/`, `@`, `$` and `#` menu (chat/ComposerCommandMenu.tsx inside ComposerBanner.Surface) and a line of
inline chips as the prompt editor shows them (ContextChip.tsx, FileTagChip.tsx, SkillInlineText.tsx,
ThreadContextChip.tsx, contextChipParts.tsx).

Class strings are copied from apps/web/src/components/chat/{ComposerCommandMenu,ComposerBanner}.tsx,
ui/{command,autocomplete,scroll-area,badge}.tsx and ContextChip.tsx at the tag in T3_VERSION. Pierre
file icons come from the installed client bundle, as in gen-markdown-spec.py.
Usage: /usr/bin/python3 -I scripts/gen-composer-menu-spec.py
"""
import glob, html, json, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESEARCH = os.environ.get("CANDY_RESEARCH") or "/Users/mrm/CandyWrapper-research"
LUCIDE = os.path.join(RESEARCH, "downloads/lucide-static-0.564.0/package/icons")
ASSETS = os.path.join(RESEARCH, "t3-client-assets")
PIERRE = open(glob.glob(os.path.join(ASSETS, "pierre-icons-*.js"))[0], encoding="utf-8").read()

def lucide(name, cls, stroke="2"):
    src = open(os.path.join(LUCIDE, name + ".svg")).read()
    inner = re.sub(r"\s+", " ", src[src.index(">", src.index("<svg")) + 1:src.index("</svg>")]).strip()
    inner = re.sub(r"<(\w+)([^>]*?)\s*/>", r"<\1\2></\1>", inner)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
            f'stroke="currentColor" stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round" class="lucide lucide-{name} {cls}" aria-hidden="true">{inner}</svg>')

ICON_COLORS = {"typescript": ("#1a85d4", "#69b1ff"), "markdown": ("#199f43", "#5ecc71")}
def pierre(token, cls="size-4 shrink-0"):
    m = re.search(r'<symbol id="file-tree-builtin-' + token + r'" viewBox="([^"]*)">(.*?)</symbol>', PIERRE, re.S)
    light, dark = ICON_COLORS[token]
    return f'<svg aria-hidden="true" data-light="{light}" data-dark="{dark}" class="{cls}" viewBox="{m.group(1)}">{m.group(2)}</svg>'

# ComposerBanner.tsx Surface, placement "attached", variant "default".
SURFACE = ("[--chat-composer-attached-surface:var(--chat-composer-glass-surface,var(--card))] dark:[--chat-composer-attached-surface:var(--chat-composer-glass-surface,var(--surface-raised))] "
           "relative isolate border-0 bg-transparent shadow-none [--chat-composer-attached-tint:transparent] "
           "[--chat-composer-attached-outline:var(--chat-composer-outline,color-mix(in_srgb,var(--contrast-foreground)_8%,transparent))] dark:[--chat-composer-attached-outline:var(--chat-composer-outline,color-mix(in_srgb,var(--color-white)_5%,transparent))] "
           "[--chat-composer-attachment-overlap:calc(1rem+1px)] before:rounded-t-2xl before:mask-t-from-transparent before:mask-t-from-4 before:mask-t-to-black before:mask-t-to-4 "
           "before:pointer-events-none before:absolute before:inset-0 before:-z-1 before:border before:border-(--chat-composer-attached-outline) "
           "before:bg-(--chat-composer-attached-surface)/(--glass-opacity) before:bg-linear-to-b before:from-(--chat-composer-attached-tint) before:to-(--chat-composer-attached-tint) before:backdrop-blur-(--glass-blur) before:backdrop-saturate-(--glass-saturation) "
           "before:shadow-composer dark:before:shadow-composer-dark dark:supports-[(backdrop-filter:blur(1px))_or_(-webkit-backdrop-filter:blur(1px))]:before:bg-composer-seam-above "
           "flex min-h-0 w-full flex-col overflow-hidden pb-(--chat-composer-attachment-overlap)")
SCROLL_ROOT = "relative size-full min-h-0 overflow-hidden rounded-[inherit]"
VIEWPORT = "h-full max-h-[inherit] overflow-auto overscroll-contain rounded-[inherit] outline-none"  # no scrollbar-gutter-stable: headless Chromium reserves a classic gutter that the app (overlay scrollbars, reference 14) does not
LIST = "not-empty:scroll-py-2 not-empty:p-2 max-h-72 min-h-0 scroll-pb-6"
ITEM = ("flex min-h-8 select-none items-center gap-2 rounded-sm px-2 text-base outline-none sm:min-h-7 sm:text-sm "
        "[&_svg:not([class*='text-'])]:text-muted-foreground py-1.5 cursor-pointer")
BADGE = ("relative inline-flex shrink-0 items-center justify-center gap-1 whitespace-nowrap rounded-sm border border-transparent font-medium outline-none "
         "[&_svg:not([class*='opacity-'])]:opacity-80 [&_svg:not([class*='size-'])]:size-3.5 sm:[&_svg:not([class*='size-'])]:size-3 [&_svg]:shrink-0 "
         "h-5.5 min-w-5.5 px-[calc(--spacing(1)-1px)] text-sm sm:h-4.5 sm:min-w-4.5 sm:text-xs bg-secondary text-secondary-foreground ms-auto")

def row(label, desc, icon="", active=False, prefix=None, badge=None):
    lab = (f'<span class="text-secondary-label">{prefix}</span>' if prefix else "") + html.escape(label)
    b = f'<span class="{BADGE}" data-slot="badge">{lucide(badge[0], "text-current")}{badge[1]}</span>' if badge else ""
    cls = ITEM + (" bg-accent! text-accent-foreground!" if active else "")
    return (f'<div role="option" class="{cls}"{" data-active" if active else ""}>{icon}'
            f'<span class="flex min-w-0 flex-1 items-center gap-2"><span class="min-w-0 max-w-[45%] shrink-0 truncate font-sans text-xs font-medium">{lab}</span>'
            f'<span class="min-w-0 flex-1 truncate text-left text-secondary-label text-xs">{html.escape(desc)}</span>{b}</span></div>')

def menu(rows):
    return (f'<div class="{SURFACE}" data-composer-banner-surface="attached"><div class="{SCROLL_ROOT}"><div class="{VIEWPORT}">'
            f'<div class="{LIST}" role="listbox"><div role="group">{"".join(rows)}</div></div></div></div></div>')

def empty(text):
    return f'<div class="{SURFACE}" data-composer-banner-surface="attached"><div class="px-5 pt-3.5 pb-7"><p class="text-secondary-label text-xs">{text}</p></div></div>'

THREAD = lucide("messages-square", "size-4 shrink-0 text-secondary-label")
FOLDER = lucide("folder", "size-4 text-icon-muted")
PR_OPEN = lucide("git-pull-request-arrow", "size-4 shrink-0 text-emerald-600 dark:text-emerald-300/90")
PR_MERGED = lucide("git-merge", "size-4 shrink-0 text-violet-600 dark:text-violet-300/90")

# ContextChip.tsx with a kind's accent, inside the editor's node view wrapper (ComposerPromptEditorTiptap.tsx:233).
CHIP = ("inline-flex h-[1.41em] max-w-full items-center gap-[0.33em] rounded-[0.5em] border px-[0.5em] align-middle font-medium text-[0.86em] leading-none "
        "[&_svg]:block [&_svg]:size-[1.17em] [&_svg]:shrink-0 [&_svg]:self-center "
        "[--context-chip-border:color-mix(in_oklab,var(--context-chip-accent)_34%,var(--contrast-border))] "
        "[--context-chip-foreground:color-mix(in_oklab,var(--context-chip-accent)_22%,var(--contrast-foreground))] "
        "border-(--context-chip-border) bg-(--context-chip-accent)/11 text-(--context-chip-foreground)")
WRAP = "relative inline-flex select-none items-center align-middle leading-none"
def chip(accent, icon, label):
    return (f'<span class="{WRAP}"><span class="{CHIP} [--context-chip-accent:{accent}]" data-slot="context-chip">{icon}'
            f'<span class="block min-w-0 self-center truncate leading-tight" data-slot="context-chip-label">{html.escape(label)}</span></span></span>')
SKILL_ICON = lucide("package", "", stroke="1.85")
chips = (f'<p class="text-sm leading-relaxed text-foreground">Use {chip("oklch(0.62_0.16_322)", SKILL_ICON, "Pdf Tools")} on '
         f'{chip("oklch(0.62_0.11_215)", pierre("typescript", ""), "api.ts")} and '
         f'{chip("oklch(0.62_0.12_190)", lucide("messages-square", ""), "Fix login")} '
         f'{chip("oklch(0.62_0.134_163)", lucide("git-pull-request-arrow", ""), "#42")}</p>')

cases = [
    {"name": "slash", "html": menu([
        row("/model", "Switch response model for this thread", active=True),
        row("/compact", "Summarize the conversation to free context"),
        row("/review", "Review the current changes"),
        row("pdf-tools", "Read and fill PDF forms", prefix="/skill:", badge=("user-round", "Personal")),
    ]), "native": {"case": "slash"}},
    {"name": "mention", "html": menu([
        row("Fix login", "Thread", icon=THREAD, active=True),
        row("api.ts", "src/server", icon=pierre("typescript")),
        row("README.md", "", icon=pierre("markdown")),
        row("components", "src", icon=FOLDER),
    ]), "native": {"case": "mention"}},
    {"name": "skill", "html": menu([
        row("Pdf Tools", "Read and fill PDF forms", active=True, badge=("user-round", "Personal Skill")),
        row("Commit", "Write a commit message", badge=("folder", "Repo Skill")),
    ]), "native": {"case": "skill"}},
    {"name": "pull-request", "html": menu([
        row("#42", "Fix the login redirect", icon=PR_OPEN, active=True),
        row("#7", "Add the settings page", icon=PR_MERGED),
    ]), "native": {"case": "pull-request"}},
    {"name": "empty", "html": empty("No matching files or folders."), "native": {"case": "empty"}},
    {"name": "chips", "html": chips, "native": {"case": "chips"}, "wrapperStyle": "display:block;width:560px"},
]
PREPARE = "(document.querySelectorAll('svg[data-light]').forEach(s => s.style.color = document.documentElement.classList.contains('dark') ? s.dataset.dark : s.dataset.light), 'ok')"
spec = {"component": "composer-menu", "source": "apps/web/src/components/chat/ComposerCommandMenu.tsx, ContextChip.tsx",
        "states": ["rest"], "themes": ["light", "dark"], "prepare": PREPARE,
        "cases": [dict({"wrapperStyle": "display:block;width:692px"}, **c) for c in cases]}
with open(os.path.join(ROOT, "design/component-reference/composer-menu.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("wrote", len(cases), "cases")
