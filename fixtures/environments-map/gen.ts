import * as M from "./logic.ts";
const now = Date.parse("2026-11-19T12:00:00.000Z");
const node = (v: string) => M.fleetEnvironmentNodeId(v);
const link = (target: string, o: any = {}) => ({ environmentId: target, label: target, urls: [`https://${target}.example.ts.net`],
  access: "approval-required", linkedAt: "2026-11-01T00:00:00.000Z", expiresAt: "2027-01-01T00:00:00.000Z",
  lastReachedAt: null, lastError: null, status: "reachable", ...o });
const environment = (name: string, links: any = [], o: any = {}) => ({ environmentId: name, label: name, machine: "server",
  phase: "connected", enabled: true, routes: [{ id: "tailnet", kind: "tailnet" }], activeRouteId: "tailnet", refusedRouteIds: [],
  offersLinks: true, canWriteAccess: true, hasLinkAddress: true,
  outgoing: typeof links !== "string" ? { state: "loaded", links } : links === "error" ? { state: "error", message: "boom" }
    : links === "loaded" ? { state: "loaded", links: [] } : { state: links }, ...o });
const connectMachine = (name: string) => ({ environmentId: name, label: name, machine: "server", availability: "online" });
const build = (envs: any[], cm: any[] = []) => M.buildFleetGraph({ clientLabel: "This browser", environments: envs, connectMachines: cm, now });
const vms = (count: number, prefix = "vm", o: any = {}) => Array.from({ length: count }, (_, i) => link(`${prefix}-${i + 1}`, o));
const setups: Record<string, () => any> = {
  one: () => build([environment("cups")]),
  large: () => build([
    environment("nucbox", [...vms(40, "fs", { access: "full-access" }), link("ci"), link("cups", { access: "auto" })],
      { routes: [{ id: "tailnet", kind: "tailnet" }, { id: "lan", kind: "lan" }, { id: "relay", kind: "relay" }] }),
    environment("cups", [link("nucbox"), link("staging", { access: "read-only" }), link("ci")]),
    environment("mbp", "unknown", { phase: "offline" }),
    environment("win", "unknown", { phase: "error" }),
    environment("vps", [link("db-1"), link("db-2"), link("db-3"), link("ci", { access: "read-only" }), link("staging", { access: "auto" }), link("cups", { access: "full-access" })]),
    environment("old", "unknown", { enabled: false, phase: "available" }),
  ], [connectMachine("gpu")]),
  shared: () => build([
    environment("nucbox", [link("fs-1", { access: "full-access" }), link("fs-2", { access: "auto" }), link("fs-3", { access: "read-only" })]),
    environment("mbp", "unknown", { phase: "reconnecting" }),
    environment("cups", [link("fs-1", { access: "full-access" }), link("fs-2", { access: "full-access" }), link("fs-3", { access: "auto" }),
      link("fs-4", { access: "auto-accept-edits" }), link("fs-5"), link("fs-6", { access: "read-only" }), link("nucbox", { access: "auto" })]),
  ]),
  huge: () => build([
    environment("nucbox", [...vms(1000, "vm", { access: "full-access" }), link("cups")]),
    environment("cups", vms(1000, "vm", { access: "full-access" })),
    environment("mbp", [link("nucbox", { access: "auto" })]),
    ...Array.from({ length: 5 }, (_, i) => environment(`gpu-${i + 1}`)),
    ...Array.from({ length: 6 }, (_, i) => environment(`lab-${i + 1}`, "unknown", { phase: "offline" })),
    ...Array.from({ length: 4 }, (_, i) => environment(`old-${i + 1}`, "unknown", { enabled: false, phase: "available" })),
    ...Array.from({ length: 2 }, (_, i) => environment(`legacy-${i + 1}`, "unknown", { phase: "unsupported" })),
  ]),
  twoWay: () => build([environment("a", [link("b")]), environment("b", [link("a")])]),
  twoApart: () => build([environment("a", [link("b")]), environment("b", [link("a", { access: "auto" })])]),
  mesh: () => { const n = ["a", "b", "c", "d", "e"]; return build(n.map((x) => environment(x, n.filter((o) => o !== x).map((o) => link(o))))); },
  legible: () => {
    const routes = (...k: string[]) => k.map((kind, i) => ({ id: `${kind}-${i}`, kind }));
    return build([
      environment("cups", "unknown", { phase: "offline", routes: routes("tailnet", "tailnet", "relay") }),
      environment("nucbox-1", [link("Julius's MacBook Pro", { access: "full-access" }), ...vms(7, "fs", { access: "full-access" }),
        ...vms(37, "gs", { access: "full-access", status: "unreachable" })], { routes: routes("lan", "tailnet", "tailnet", "relay"), activeRouteId: "lan-0" }),
      environment("Julius's MacBook Pro"),
    ]);
  },
  health: () => build([environment("a", [link("b", { status: "expired" }), link("c", { lastError: "401" }), link("d", { status: "unreachable" }), link("e", { expiresAt: "2026-11-21T00:00:00.000Z" })]), environment("b", "loading"), environment("c", "off", { canWriteAccess: false })]),
};
const r = (x: any) => x && [x.x, x.y, x.width, x.height];
const dump = (l: any) => ({
  nodes: [...l.nodes].map(([k, v]: any) => [k, r(v)]),
  stacks: [...l.stacks].map(([k, v]: any) => [k, { rect: r(v.rect), face: r(v.face), tray: r(v.tray), more: r(v.more), lines: v.lines.map((x: any) => [x.sourceId, x.access, x.d, x.arrow && [x.arrow.x, x.arrow.y]]) }]),
  routes: [...l.routes].map(([k, v]: any) => [k, v.d, r(v.pill)]),
  links: [...l.links].map(([k, v]: any) => [k, v.d, [v.arrow.x, v.arrow.y, v.arrow.dir], v.twoWay && [v.twoWay.backArrow.x, v.twoWay.backArrow.y, v.twoWay.forward, v.twoWay.back], v.badge && [...r(v.badge), v.badge.side, v.badge.onDemand]]),
  handles: [...l.handles].map(([k, v]: any) => [k, v.x, v.y]),
  columns: l.columns.map((c: any) => [c.id, c.x]), width: l.width, height: l.height,
});
const out: any = {};
for (const [name, make] of Object.entries(setups)) {
  const graph = make();
  const closed = M.fleetStacks(graph, new Set());
  const variants: Array<[string, any[]]> = [["closed", closed]];
  if (closed.length > 0) variants.push(["open", M.fleetStacks(graph, new Set(closed.map((s: any) => s.id)))]);
  const cs: any = { stacks: closed.map((s: any) => [s.id, s.kind, s.memberIds.length, s.reachable, s.shownIds.length, s.firstLabel, s.lastLabel]),
    summary: M.fleetSummary(graph), shapeKeyLength: M.fleetShapeKey(graph, closed).length, layouts: {} };
  for (const [v, stacks] of variants) for (const w of [null, 560, 900, 1400]) {
    const l = M.layoutFleetGraph(graph, stacks, w ?? undefined);
    cs.layouts[`${v}@${w ?? "regular"}`] = { ...dump(l), canvasHeight: w && M.fleetCanvasHeight(l, w, { min: 180, max: 840 }),
      fit: w && M.fitFleetLayout(l, { width: w, height: M.fleetCanvasHeight(l, w, { min: 180, max: 840 }) }) };
  }
  out[name] = cs;
}
console.log(JSON.stringify(out));
