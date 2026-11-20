"""Writes design/component-reference/tunnel-usage.json for scripts/component-reference: the 4928 T3 Connect tunnel
meter under the Connections row, and the alert after the relay refuses a tunnel at the cap.

Markup is copied from apps/web/src/components/cloud/TunnelUsage.tsx (TunnelUsageMeter, TunnelLimitAlert),
components/settings/SavedEnvironmentRows.tsx:542-556 (the `flex flex-col gap-3 pb-3` wrapper), ui/alert.tsx and
ui/button.tsx (`inlineButtonVariants`) at the tag in T3_VERSION. Button markup comes from scripts/gen-button-spec.py.
Usage: /usr/bin/python3 -I scripts/gen-tunnel-usage-spec.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ns = {"__file__": os.path.join(ROOT, "scripts/gen-connections-spec.py")}
src = open(os.path.join(ROOT, "scripts/gen-connections-spec.py")).read()
exec(src[:src.index("def machine(")], ns)
button, lucide = None, ns["lucide"]
btn_ns = ns["btn_ns"]


def btn(variant, size, text):
    cls = ns["merge"](f'{btn_ns["BASE"]} {btn_ns["VARIANTS"][variant]} {btn_ns["SIZES"][size]}')
    return f'<button type="button" class="{cls}" data-slot="button">{text}</button>'


INLINE = ("inline-flex shrink-0 cursor-pointer items-center gap-0.5 font-medium underline-offset-2 [text-align:var(--inline-button-text-align,center)] "
          "[white-space:var(--inline-button-white-space,nowrap)] hover:underline focus-visible:outline-2 focus-visible:outline-ring "
          "disabled:pointer-events-none disabled:opacity-64 text-foreground")


def meter(used, limit, action=None):
    full = used >= limit
    fill = "bg-warning" if full else "bg-foreground/72"
    if limit <= 10:
        bar = "".join(f'<span class="flex-1 rounded-full {fill if i < used else "bg-muted"}"></span>' for i in range(limit))
    else:
        bar = (f'<span class="flex-1 overflow-hidden rounded-full bg-muted"><span class="block h-full rounded-full {fill}" '
               f'style="width: {min(100, used / limit * 100)}%"></span></span>')
    act = f'<button type="button" class="{INLINE}">{action}</button>' if action else ""
    return ('<div class="flex max-w-sm flex-col gap-1.5"><div class="flex items-baseline justify-between gap-3 text-xs">'
            f'<span class="tabular-nums {"text-warning-foreground" if full else "text-foreground"}">{used} of {limit} tunnels in use</span>{act}</div>'
            f'<div role="meter" aria-valuemin="0" aria-valuemax="{limit}" aria-valuenow="{used}" class="flex h-1.5 gap-1">{bar}</div></div>')


def limit_alert(description, action):
    return ('<div class="relative rounded-xl border px-3.5 py-3 text-card-foreground text-sm border-warning/32 bg-warning-surface text-warning-foreground '
            '[&_[data-slot=alert-description]]:text-warning-foreground/80 [&_svg]:text-warning" data-slot="alert" data-variant="warning" role="alert">'
            f'<div class="flex gap-2 items-center"><div class="flex shrink-0 items-center justify-center size-4 [&>svg]:size-full">{lucide("triangle-alert")}</div>'
            '<div class="flex min-w-0 flex-1 flex-col gap-0.5"><div class="font-medium" data-slot="alert-title">You’re out of tunnels (they cost us money).</div>'
            f'<div class="flex flex-col gap-2.5 text-muted-foreground" data-slot="alert-description">{description}</div></div>'
            f'<div class="flex shrink-0 items-center self-center"><div class="flex gap-1" data-slot="alert-action">{action}</div></div></div></div>')


def wrap(*parts):
    return f'<div class="flex flex-col gap-3 pb-3">{"".join(parts)}</div>'


W = "display:block;width:732px"
cases = [
    {"name": "tunnel-usage.meter", "html": wrap(meter(1, 3, "Get more tunnels")), "wrapperStyle": W,
     "native": {"used": "1", "limit": "3", "upgrade": "link"}},
    {"name": "tunnel-usage.track", "html": wrap(meter(12, 100)), "wrapperStyle": W,
     "native": {"used": "12", "limit": "100", "upgrade": ""}},
    {"name": "tunnel-usage.refused", "html": wrap(meter(3, 3), limit_alert(
        "Switch to Tailscale or get more tunnels by linking your T3 Chat sub (sorry!)", btn("default", "sm", "Link T3 Chat"))),
     "wrapperStyle": W, "native": {"used": "3", "limit": "3", "upgrade": "link", "refused": "3"}},
]
spec = {"component": "tunnel-usage", "source": "apps/web/src/components/cloud/TunnelUsage.tsx", "states": ["rest"],
        "themes": ["light", "dark"], "cases": cases}
with open(os.path.join(ROOT, "design/component-reference/tunnel-usage.json"), "w") as f:
    json.dump(spec, f, indent=1, ensure_ascii=False)
print("tunnel-usage", len(cases), "cases")
