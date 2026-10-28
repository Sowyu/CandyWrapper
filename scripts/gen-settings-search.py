"""Writes Packages/CandyKit/Sources/Features/Settings/SettingsSearchCatalog.generated.swift from T3's
settings search catalog (`SETTINGS_SEARCH_ITEMS` in apps/web/src/components/settings/settingsSearch.ts),
so the ids, titles, aliases, scopes and availability flags stay T3's. The keybinding commands
(`...KEYBINDING_SEARCH_ITEMS`) are built at run time from the ported keymap.
Usage: /usr/bin/python3 -I scripts/gen-settings-search.py [t3code checkout]
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T3 = sys.argv[1] if len(sys.argv) > 1 else "/Users/mrm/CandyWrapper-research/t3code"
src = open(os.path.join(T3, "apps/web/src/components/settings/settingsSearch.ts")).read()
start = src.index("export const SETTINGS_SEARCH_ITEMS = [") + len("export const SETTINGS_SEARCH_ITEMS = [")
body = src[start:src.index("] as const satisfies ReadonlyArray<SettingsSearchItem>;", start)]
body = re.sub(r"//[^\n]*", "", body)

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
         "managedTunnelOnly", "secondary", "requiresThreadAutoSettlement", "peerLinksOnly"]
PATHS = {"/settings/chat": "chat", "/settings/diffs": "diffs", "/settings/threads": "threads",
         "/settings/browser": "browser", "/settings/devices": "devices", "/settings/worktrees": "worktrees",
         "/settings/access": "access", "/settings/maintenance": "maintenance", "/settings/labs": "beta", "/settings/about": "about",
         "/settings/projects": "projects", "/settings/general": "general", "/settings/diagnostics": "diagnostics",
         "/settings/appearance": "appearance",
         "/settings/keybindings": "keybindings", "/settings/snap-shot": "snapShots", "/settings/providers": "providers",
         "/settings/integrations": "integrations", "/settings/scheduled-tasks": "scheduledTasks",
         "/settings/source-control": "sourceControl", "/settings/storage": "storage", "/settings/connections": "connections", "/settings/beta": "beta",
         "/settings/archived": "archive"}


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

out = f"""// Generated by scripts/gen-settings-search.py from apps/web/src/components/settings/settingsSearch.ts
// (`SETTINGS_SEARCH_ITEMS`) at the tag in T3_VERSION. Do not edit; run the script again.

extension SettingsSearch {{
    enum CatalogEntry {{ case item(SettingsSearchItem), keybindings }}

    static let catalogEntries: [CatalogEntry] = [
{chr(10).join(lines)}
    ]
}}
"""
path = os.path.join(ROOT, "Packages/CandyKit/Sources/Features/Settings/SettingsSearchCatalog.generated.swift")
open(path, "w").write(out)
print("settings search:", sum(1 for k, _ in entries if k == "item"), "items,", sum(1 for _ in host_items()), "host items")
