"""Writes design/component-reference/banner-stack.json for scripts/component-reference: the composer
notices CandyWrapper produces (ChatView.tsx:2535-2596, 3091-3224, 7506-7541; UsageLimitRecoveryBanner.tsx)
as ComposerBannerStack items (ComposerBannerStack.tsx:330-370 on ComposerBanner.tsx), in every variant,
and the stack itself: collapsed with its peek, and expanded with floating notices above the front item
(ComposerBannerStack.tsx:120-250, ComposerBanner.tsx:84-115, 125-145).

Class strings are copied from those files at the tag in T3_VERSION; buttons and tailwind-merge come from
gen-button-spec.py through gen-composer-attachments-spec.py.
Usage: /usr/bin/python3 -I scripts/gen-banner-stack-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(script, stop):
    ns = {"__file__": os.path.join(ROOT, "scripts", script)}
    src = open(os.path.join(ROOT, "scripts", script)).read()
    exec(src[:src.index(stop)], ns)
    return ns


B = load("gen-composer-attachments-spec.py", "def entry_row(")
lucide, btn = B["lucide"], B["btn"]

# ComposerBanner.tsx:12-35
SURFACE_COLORS = ("[--chat-composer-attached-surface:var(--chat-composer-glass-surface,var(--card))] "
                  "dark:[--chat-composer-attached-surface:var(--chat-composer-glass-surface,var(--surface-raised))]")
NEUTRAL = ("[--chat-composer-attached-outline:var(--chat-composer-outline,color-mix(in_srgb,var(--contrast-foreground)_8%,transparent))] "
           "dark:[--chat-composer-attached-outline:var(--chat-composer-outline,color-mix(in_srgb,var(--color-white)_5%,transparent))]")
VARIANTS = {
    "default": NEUTRAL,
    "error": "[--chat-composer-attached-outline:color-mix(in_srgb,var(--error)_32%,transparent)] [--chat-composer-attached-tint:color-mix(in_srgb,var(--error)_8%,transparent)]",
    "warning": "[--chat-composer-attached-outline:color-mix(in_srgb,var(--warning)_28%,transparent)] [--chat-composer-attached-tint:color-mix(in_srgb,var(--warning)_8%,transparent)]",
}
# ComposerBanner.tsx:38-71 (`Surface`); tailwind-merge drops the transparent tint when a variant sets one.
def surface(variant, placement):
    tint = "" if variant != "default" else " [--chat-composer-attached-tint:transparent]"
    place = ("[--chat-composer-attachment-overlap:calc(1rem+1px)] before:rounded-t-2xl before:mask-t-from-transparent before:mask-t-from-4 before:mask-t-to-black before:mask-t-to-4"
             if placement == "attached" else "[--chat-composer-attachment-overlap:0px] before:rounded-2xl")
    return (f"{SURFACE_COLORS} relative isolate border-0 bg-transparent shadow-none{tint} {VARIANTS[variant]} {place} "
            "before:pointer-events-none before:absolute before:inset-0 before:-z-1 before:border before:border-(--chat-composer-attached-outline) "
            "before:bg-(--chat-composer-attached-surface)/(--glass-opacity) before:bg-linear-to-b before:from-(--chat-composer-attached-tint) before:to-(--chat-composer-attached-tint) before:backdrop-blur-(--glass-blur) before:backdrop-saturate-(--glass-saturation) "
            "before:shadow-composer dark:before:shadow-composer-dark "
            "dark:supports-[(backdrop-filter:blur(1px))_or_(-webkit-backdrop-filter:blur(1px))]:before:bg-composer-seam-above")

ACTION = lambda label: btn("ghost", "xs", label)
DISMISS = btn("ghost", "icon-xs", lucide("x", "size-3.5"))


# ComposerBannerStack.tsx:330-370 (`ComposerBannerStackAlert`) with `density="comfortable"`.
def alert(variant, icon, title, description=None, actions=(), dismiss=False, compact=False, placement="attached"):
    desc = ""
    if description:
        desc = (f'<span class="contents"><span class="min-w-0 truncate text-muted-foreground shrink-[9999] @max-[400px]:sr-only">{description}</span></span>'
                if compact else f'<span class="flex min-w-8 flex-1 items-center gap-1"><span class="min-w-0 truncate text-muted-foreground">{description}</span></span>')
    acts = ""
    if actions or dismiss:
        acts = f'<span data-slot="composer-banner-actions" class="{B["ACTIONS"]}">' + "".join(ACTION(a) for a in actions) + (DISMISS if dismiss else "") + "</span>"
    row = B["ROW"] + ("" if acts else " grid-cols-[var(--composer-banner-icon-column)_minmax(0,1fr)]")
    return (f'<div role="alert" data-composer-banner-surface="{placement}" class="{surface(variant, placement)} {B["ROOT_CLS"]} [--composer-banner-padding-block:--spacing(1.25)] @container">'
            f'<div data-composer-banner-row="true" class="{row}"><span class="{B["ICON"]} h-(--composer-banner-icon-column) self-start">{lucide(icon)}</span>'
            f'<span class="{B["CONTENT"]} whitespace-nowrap"><span class="min-w-0 truncate font-medium leading-7 sm:leading-6">{title}</span>{desc}</span>'
            f'{acts}</div></div>')


GOAL = dict(variant="default", icon="target", title="Goal · 12k tokens", description="Ship the stack port with motion", actions=("Clear",))
RECOVERY = dict(variant="warning", icon="gauge", title="Usage limit reached", description="Resets 10/12/2026, 5:00 PM",
                actions=("Resume at reset", "Snooze until reset"))
ENVIRONMENT = dict(variant="warning", icon="wifi-off", title="Local is reconnecting")
OFFLINE = dict(variant="error", icon="wifi-off", title="Remote is offline", actions=("Reconnect", "Disconnect server"))
CLONE = dict(variant="error", icon="download", title="Failed to clone demo-repo", description="Repository not found.",
             actions=("Remove project", "Retry"), compact=True)
NOTICE = dict(variant="default", icon="info", title="Server update available", description="Restart the server to update", dismiss=True)

PEEK_BORDER = {"default": "border-(--chat-composer-attached-outline)", "error": "border-destructive/24", "warning": "border-warning/24"}


# ComposerBannerStack.tsx:120-250 and ComposerBanner.tsx:84-145: the notices, then the front attachment,
# in a `ComposerBanner.Column`.
def stack(front, stacked, expanded):
    peek = (f'<button type="button" data-slot="composer-banner-peek" class="{SURFACE_COLORS} {NEUTRAL} absolute inset-x-0 bottom-0 z-0 mx-auto h-3 w-[96%] cursor-pointer rounded-t-2xl border border-b-0 shadow-md '
            "bg-(--chat-composer-attached-surface)/(--glass-opacity) backdrop-blur-(--glass-blur) backdrop-saturate-(--glass-saturation) transition-opacity duration-150 ease-out "
            f'{PEEK_BORDER[stacked[0]["variant"]]}' + (" pointer-events-none invisible opacity-0" if expanded else "") + '"></button>')
    items = "".join(f'<div class="transition-[opacity,translate] duration-220 ease-in opacity-100">{alert(**s, placement="floating")}</div>' for s in stacked)
    shown = "pointer-events-auto visible translate-y-0 opacity-100" if expanded else "pointer-events-none invisible translate-y-1 opacity-0"
    notices = (f'<div class="relative z-20 min-h-3{" z-50" if expanded else ""}">{peek}'
               f'<div role="group" class="grid transition-[grid-template-rows] duration-150 ease-out {"grid-rows-[1fr]" if expanded else "grid-rows-[0fr]"}">'
               f'<div class="min-h-0 overflow-hidden"><div class="transform-gpu space-y-2 pb-2 transition-[opacity,transform] duration-150 ease-out will-change-[opacity,transform] {shown}">'
               f'{items}</div></div></div></div>')
    attachment = ('<div data-slot="composer-banner-attachment" class="mx-auto -mb-[calc(1rem+1px)] w-[calc(100%-2*var(--chat-composer-drawer-inset))] relative z-0">'
                  f'<div class="relative z-10 transition-[opacity,translate] duration-220 ease-in opacity-100">{alert(**front)}</div></div>')
    return ('<div class="flex min-w-0 flex-1 flex-col empty:hidden [&>[data-slot=composer-banner-attachment]]:w-full [&>[data-slot=composer-banner-attachment]:last-child]:mb-0">'
            f'{notices}{attachment}</div>')


W = "display:block;width:692px"
cases = [
    {"name": "goal", "html": alert(**GOAL), "wrapperStyle": W, "native": {"kind": "goal"}},
    {"name": "recovery", "html": alert(**RECOVERY), "wrapperStyle": W, "native": {"kind": "recovery"}},
    {"name": "environment", "html": alert(**ENVIRONMENT), "wrapperStyle": W, "native": {"kind": "environment"}},
    {"name": "offline", "html": alert(**OFFLINE), "wrapperStyle": W, "native": {"kind": "offline"}},
    {"name": "clone-failed", "html": alert(**CLONE), "wrapperStyle": W, "native": {"kind": "clone"}},
    {"name": "notice-dismiss", "html": alert(**NOTICE), "wrapperStyle": W, "native": {"kind": "notice"}},
    {"name": "floating", "html": alert(**RECOVERY, placement="floating"), "wrapperStyle": W, "native": {"kind": "floating"}},
    {"name": "stack-collapsed", "html": stack(GOAL, [RECOVERY, ENVIRONMENT], False), "wrapperStyle": W, "native": {"kind": "stack"}},
    {"name": "stack-collapsed-neutral", "html": stack(RECOVERY, [NOTICE], False), "wrapperStyle": W, "native": {"kind": "stack-neutral"}},
    {"name": "stack-expanded", "html": stack(GOAL, [RECOVERY, ENVIRONMENT], True), "wrapperStyle": W, "native": {"kind": "stack-open"}},
]
spec = {"component": "banner-stack", "source": "apps/web/src/components/chat/ComposerBannerStack.tsx, ComposerBanner.tsx, ChatView.tsx",
        "states": ["rest"], "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/banner-stack.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("banner-stack", len(cases), "cases")
