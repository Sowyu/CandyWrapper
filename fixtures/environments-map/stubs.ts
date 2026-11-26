export const AuthMcpClientAccess = { literals: ["read-only","approval-required","auto-accept-edits","auto","full-access"] };
export function peerLinkHealth(link: any, now: number): any {
  const exp = Date.parse(link.expiresAt);
  if (link.status === "expired" || exp <= now) return { kind: "expired" };
  if (link.status === "unreachable") return { kind: "unreachable", detail: link.lastError };
  if (link.lastError !== null) return { kind: "failing", detail: link.lastError };
  const days = Math.ceil((exp - now) / 86400000);
  return { kind: "reachable", expiresInDays: days <= 5 ? days : null };
}
export const linkBackOffer = (input: any): any => {
  const { target, source } = input;
  if (target === null || !target.connected || !source.connected) return { kind: "hidden" };
  if (!target.offersLinks) return { kind: "blocked", reason: "target_links_off" };
  if (!target.writable) return { kind: "blocked", reason: "target_no_access" };
  if (!source.writable) return { kind: "blocked", reason: "source_no_access" };
  if (source.urls.length === 0) return { kind: "blocked", reason: "source_no_address" };
  if (target.links === null || target.links.some((l: any) => l.environmentId === source.environmentId && l.status !== "expired")) return { kind: "hidden" };
  return { kind: "offered" };
};
