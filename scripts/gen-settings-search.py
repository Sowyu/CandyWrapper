"""Writes Packages/CandyKit/Sources/Features/Settings/SettingsSearchCatalog.generated.swift from T3's
settings search catalog (`SETTINGS_SEARCH_ITEMS` in apps/web/src/components/settings/settingsSearch.ts),
so the ids, titles, aliases, scopes and availability flags stay T3's. The keybinding commands
(`...KEYBINDING_SEARCH_ITEMS`) are built at run time from the ported keymap.
Usage: /usr/bin/python3 -I scripts/gen-settings-search.py [t3code checkout]
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T3 = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/CandyWrapper-research/t3code")
src = open(os.path.join(T3, "apps/web/src/components/settings/settingsSearch.ts")).read()
start = src.index("export const SETTINGS_SEARCH_ITEMS = [") + len("export const SETTINGS_SEARCH_ITEMS = [")
body = src[start:src.index("] as const satisfies ReadonlyArray<SettingsSearchItem>;", start)]
body = re.sub(r"//[^\n]*", "", body)
# Since 4928 titles are `msg("Title")` or `msg("Title", { $context: "..." })` for translation; keep the literal.
body = re.sub(r'msg\(\s*("(?:[^"\\]|\\.)*")\s*(?:,\s*\{[^}]*\}\s*)?,?\s*\)', r"\1", body)

# Since 3669 the hosts come from the forge definitions (packages/source-control-definitions/src/registry.ts):
# SOURCE_CONTROL_HOST_LABELS and SOURCE_CONTROL_HOST_TERMS join their labels and keywords in registry order,
# and sourceControlHostSearchItems adds one item per host with settings (settingsSearch.ts:119-155).
def schema_keys(text):
    """The top-level keys of the object `makeProviderSettingsSchema(` gets, as `Object.keys(settings.fields)`."""
    i = text.index("{", text.index("makeProviderSettingsSchema(", text.index("export const settings")))
    keys, depth, expect = [], 0, False
    while i < len(text):
        c = text[i]
        if c in "\"'`":
            j = i + 1
            while text[j] != c:
                j += 2 if text[j] == "\\" else 1
            i = j
        elif c in "{([":
            depth += 1
            expect = depth == 1
        elif c in "})]":
            depth -= 1
            if depth == 0:
                return keys
        elif depth == 1 and c == ",":
            expect = True
        elif depth == 1 and expect and not c.isspace():
            m = re.match(r"(\w+)\s*:", text[i:])
            if m:
                keys.append(m.group(1))
            expect = False
        i += 1
    return keys

forges = []
registry_path = os.path.join(T3, "packages/source-control-definitions/src/registry.ts")
if os.path.exists(registry_path):
    registry = open(registry_path).read()
    imports = dict(re.findall(r'import \* as (\w+) from "@t3tools/(source-control-[\w-]+)/shared/definition"', registry))
    order = re.findall(r"(\w+)\.definition,", registry[registry.index("makeSourceControlDefinitionRegistry("):])
    for alias in order:
        text = open(os.path.join(T3, "packages", imports[alias], "src/shared/definition.ts")).read()
        d = text[text.index("export const definition"):]
        keywords = re.search(r"searchKeywords:\s*\[([^\]]*)\]", d)
        cli = re.search(r"credentials:\s*\{[^}]*?cliName:\s*\"([^\"]+)\"", d, re.S)
        has_settings = re.search(r"^\s*settings,?$", d, re.M) is not None
        fields = []
        if has_settings and not cli:
            fields = schema_keys(text)
        forges.append({"kind": re.search(r'KIND = SourceControlProviderKind\.make\("([^"]+)"\)', text).group(1), "label": re.search(r'label:\s*"([^"]+)"', d).group(1),
                       "keywords": re.findall(r'"([^"]+)"', keywords.group(1)) if keywords else [], "cli": cli.group(1) if cli else None,
                       "settings": has_settings, "fields": fields})
values = {"SOURCE_CONTROL_HOST_LABELS": " ".join(f["label"] for f in forges),
          "SOURCE_CONTROL_HOST_TERMS": " ".join(w for f in forges for w in [f["label"], *f["keywords"]])}

def template(m):
    text = re.sub(r"\$\{(\w+)\}", lambda v: values[v.group(1)], m.group(1))
    return json.dumps(text)
body = re.sub(r"`([^`]*)`", template, body)

def host_items():
    for f in forges:
        if not f["settings"]:
            continue
        names = " ".join([f["label"], *f["keywords"]])
        title = f'{f["label"]} accounts and token' if f["cli"] else f'{f["label"]} credentials'
        terms = (f'{names} {f["cli"]} account login user host switch multiple accounts disable sign in token personal access token pat api key credential'
                 if f["cli"] else f'{names} {" ".join(f["fields"])} token credentials sign in')
        yield (f'        .item(SettingsSearchItem(id: "source-control-host-{f["kind"]}", title: {json.dumps(title)}, to: .sourceControl, '
               f'scope: .environmentDefaults, searchTerms: [{json.dumps(terms)}], flags: [.environmentOnly])),')

# CandyWrapper keeps T3's name out of its own settings.
TITLES = {"Open pull requests in T3 Code": "Open pull requests in CandyWrapper"}

STRING = r'"(?:[^"\\]|\\.)*"'
FLAGS = ["desktopOnly", "macOnly", "windowsOnly", "cloudOnly", "environmentOnly", "providerSettingsOnly",
         "macProviderSettingsOnly", "localBackendManagementOnly", "localEnvironmentOnly", "wslAvailableOnly",
         "managedTunnelOnly", "secondary", "requiresThreadAutoSettlement", "peerLinksOnly", "primaryEnvironmentOnly",
         "fastWorktreeCheckoutOnly", "textGeneratorsOnly", "releaseChannelOnly", "secretsFeatureOnly"]
PATHS = {"/settings/chat": "chat", "/settings/diffs": "diffs", "/settings/threads": "threads",
         "/settings/browser": "browser", "/settings/devices": "devices", "/settings/worktrees": "worktrees",
         "/settings/access": "access", "/settings/maintenance": "maintenance", "/settings/labs": "beta", "/settings/about": "about",
         "/settings/projects": "projects", "/settings/general": "general", "/settings/diagnostics": "diagnostics",
         "/settings/appearance": "appearance",
         "/settings/keybindings": "keybindings", "/settings/snap-shot": "snapShots", "/settings/providers": "providers",
         "/settings/integrations": "integrations", "/settings/scheduled-tasks": "scheduledTasks",
         "/settings/source-control": "sourceControl", "/settings/storage": "storage", "/settings/connections": "connections", "/settings/beta": "beta",
         "/settings/archived": "archive"}

# CandyWrapper's own rows that 4928's catalog no longer lists, each placed after the T3 item it followed: the Cursor
# Keychain switch shown to servers that still send the setting.
KEEP_AFTER = {
    "providers": '        .item(SettingsSearchItem(id: "cursor-keychain-usage", title: "Cursor account usage", to: .providers, searchTerms: ["cursor macOS keychain usage tokens cost limits permission"], flags: [.providerSettingsOnly, .macProviderSettingsOnly])),',
}

# CandyWrapper's own Redesign tab (RedesignSettingsView), after T3's items, in the tab's order, then its Labs rows.
CANDY_ITEMS = [
    '        .item(SettingsSearchItem(id: "redesign", title: "Redesign", to: .redesign, searchTerms: ["theme look dither picture wallpaper candywrapper own experimental"])),',
    '        .item(SettingsSearchItem(id: "redesign-picture", title: "Picture", to: .redesign, searchTerms: ["redesign background wallpaper image photo desktop picture art"])),',
    '        .item(SettingsSearchItem(id: "redesign-background", title: "Background", to: .redesign, searchTerms: ["redesign picture wallpaper dither blur gradient halftone dots soft backdrop no picture"])),',
    '        .item(SettingsSearchItem(id: "redesign-ink", title: "Ink", to: .redesign, searchTerms: ["redesign picture dither dots ink colour color hue auto accent custom two inks"])),',
    '        .item(SettingsSearchItem(id: "redesign-tint", title: "Tint from picture", to: .redesign, searchTerms: ["redesign picture wallpaper color colour tint hue match surfaces"])),',
    '        .item(SettingsSearchItem(id: "redesign-gradient-animate", title: "Animate gradient", to: .redesign, searchTerms: ["redesign gradient dither dots motion move animate animation drift"])),',
    '        .item(SettingsSearchItem(id: "background-dim", title: "Background dim", to: .redesign, searchTerms: ["redesign blur picture wallpaper darken dim scrim opacity"])),',
    '        .item(SettingsSearchItem(id: "accent-color", title: "Accent color", to: .redesign, searchTerms: ["redesign accent colour tint highlight switches send focus selection"])),',
    '        .item(SettingsSearchItem(id: "ignore-reduce-transparency", title: "Ignore Reduce Transparency", to: .redesign, searchTerms: ["redesign glass blur accessibility reduce transparency picture"])),',
    '        .item(SettingsSearchItem(id: "composer-collapse", title: "Collapse composer on scroll", to: .redesign, searchTerms: ["composer rest resting scroll wheel conversation timeline shrink minimize"])),',
    '        .item(SettingsSearchItem(id: "redesign-stacked-picker", title: "Stacked model picker", to: .redesign, searchTerms: ["redesign model picker column docked reasoning layout one column details pane cost description scroll"])),',
    '        .item(SettingsSearchItem(id: "redesign-picker-account", title: "Account and limits in the model picker", to: .redesign, searchTerms: ["redesign model picker account usage limits manage provider card email plan details pane"])),',
    # CandyWrapper's own experiments, in Labs below T3's Beta group (BetaSettingsView.candyToggles).
    '        .item(SettingsSearchItem(id: "thread-tabs", title: "Tabs", to: .beta, searchTerms: ["experimental tab strip open threads pages cmd click new tab redesign"])),',
]

# Pages CandyWrapper doesn't have yet: voice dictation and the secrets store. Their rows stay out of search.
UNPORTED_PATHS = {"/settings/voice", "/settings/secrets"}
# 4928 rows CandyWrapper doesn't draw yet, so a search never lands on a page without them. Remove an id when its row lands.
UNPORTED_IDS = {"screen-reader-announcements", "simlock-hosts",
                "worktree-fast-checkout", "keep-awake-while-agents-work", "ghq-clone-layout", "welcome-page", "text-generators",
                "device-sources"}


def swift_string(literal):
    return literal  # TS double-quoted literals are valid Swift literals for this catalog's text.


entries, i, depth, block_start = [], 0, 0, None
while i < len(body):
    ch = body[i]
    if ch == '"':
        m = re.match(STRING, body[i:])
        i += len(m.group(0))
        continue
    if ch == "{":
        if depth == 0:
            block_start = i
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            entries.append(("item", body[block_start:i + 1]))
    elif depth == 0 and body.startswith("...KEYBINDING_SEARCH_ITEMS", i):
        entries.append(("keybindings", None))
    elif depth == 0 and body.startswith("...sourceControlHostSearchItems(", i):
        entries.append(("hosts", None))
    i += 1

lines = []
for kind, text in entries:
    if kind == "keybindings":
        lines.append("        .keybindings,")
        continue
    if kind == "hosts":
        lines.extend(host_items())
        continue
    fields = {}
    for m in re.finditer(r"(\w+):\s*(" + STRING + r"|true|false|\[[^\]]*\])", text):
        fields.setdefault(m.group(1), m.group(2))
    title = fields["title"].strip('"')
    if fields["to"].strip('"') in UNPORTED_PATHS or fields["id"].strip('"') in UNPORTED_IDS:
        continue
    args = [f'id: {fields["id"]}', f'title: {json.dumps(TITLES.get(title, title))}', f'to: .{PATHS[fields["to"].strip(chr(34))]}']
    if "targetId" in fields:
        args.append(f'targetId: {fields["targetId"]}')
    if "scope" in fields:
        scope = fields["scope"].strip('"')
        args.append("scope: ." + {"environment-defaults": "environmentDefaults", "project-defaults": "projectDefaults"}.get(scope, scope))
    if "searchTerms" in fields:
        terms = re.findall(STRING, fields["searchTerms"])
        args.append("searchTerms: [" + ", ".join(terms) + "]")
    flags = [f for f in FLAGS if fields.get(f) == "true"]
    if flags:
        args.append("flags: [" + ", ".join("." + f for f in flags) + "]")
    lines.append("        .item(SettingsSearchItem(" + ", ".join(args) + ")),")
    if fields["id"].strip('"') in KEEP_AFTER:
        lines.append(KEEP_AFTER[fields["id"].strip('"')])

out = f"""// Generated by scripts/gen-settings-search.py from apps/web/src/components/settings/settingsSearch.ts
// (`SETTINGS_SEARCH_ITEMS`) at the tag in T3_VERSION. Do not edit; run the script again.

extension SettingsSearch {{
    enum CatalogEntry {{ case item(SettingsSearchItem), keybindings }}

    static let catalogEntries: [CatalogEntry] = [
{chr(10).join(lines + CANDY_ITEMS)}
    ]
}}
"""
path = os.path.join(ROOT, "Packages/CandyKit/Sources/Features/Settings/SettingsSearchCatalog.generated.swift")
open(path, "w").write(out)
print("settings search:", sum(1 for k, _ in entries if k == "item"), "items,", sum(1 for _ in host_items()), "host items")
