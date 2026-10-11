#!/usr/bin/env python3
"""Signs an outside agent in to a T3 environment's MCP server the way Claude Code
or Codex does (docs/user/outside-agents.md), then checks /mcp and revokes it.

It sends what T3's approval page sends (ConnectAgentSurface.tsx:114 and 145):
discovery, dynamic registration, authorize, approval, a pairing-code decision,
the token exchange with PKCE, an MCP initialize and tools/list. Then it finds the
agent among the authorized clients, revokes it, and checks /mcp refuses the token.

Only point it at the sandbox server. Usage:
  scripts/outside-agent-smoke.py --server http://127.0.0.1:47391 \
      --token-file ../CandyWrapper-research/sandbox/session.token [--code CODE] \
      [--access read-only] [--keep]
Without --code it creates a one-time pairing code itself with the session token.
--keep leaves the agent signed in, so it can be revoked from CandyWrapper.
"""
import argparse, base64, hashlib, json, os, secrets, sys, urllib.error, urllib.parse, urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


opener = urllib.request.build_opener(NoRedirect)


def call(method, url, body=None, headers=None, form=False):
    data = None
    headers = dict(headers or {})
    if body is not None:
        if form:
            data = urllib.parse.urlencode(body).encode()
            headers["content-type"] = "application/x-www-form-urlencoded"
        else:
            data = json.dumps(body).encode()
            headers["content-type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        resp = opener.open(req)
    except urllib.error.HTTPError as e:
        resp = e
    raw = resp.read().decode() if resp.fp else ""
    return resp.status, dict(resp.headers), raw


def step(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + (": " + detail if detail else ""))
    if not ok:
        sys.exit(1)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--server", required=True)
    p.add_argument("--token-file", required=True)
    p.add_argument("--code")
    p.add_argument("--access", default="read-only")
    p.add_argument("--keep", action="store_true")
    p.add_argument("--check-revoked", metavar="TOKEN_FILE", help="only check that /mcp refuses the token a --keep run saved")
    a = p.parse_args()
    base = a.server.rstrip("/")
    if a.check_revoked:
        kept = {"authorization": "Bearer " + open(a.check_revoked).read().strip(), "accept": "application/json, text/event-stream"}
        s, _, _ = call("POST", base + "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "cw-smoke", "version": "1"}}}, kept)
        step("revoked token refused", s == 401, "HTTP %d" % s)
        return
    admin = {"authorization": "Bearer " + open(a.token_file).read().strip()}

    # 1. The agent calls /mcp without a token and learns where to sign in.
    s, h, _ = call("POST", base + "/mcp", {"jsonrpc": "2.0", "id": 0, "method": "ping"})
    challenge = {k.lower(): v for k, v in h.items()}.get("www-authenticate", "")
    step("401 with resource metadata", s == 401 and "resource_metadata=" in challenge, challenge)
    s, _, raw = call("GET", base + "/.well-known/oauth-protected-resource/mcp")
    resource = json.loads(raw)
    step("protected resource", s == 200, resource["resource"])
    s, _, raw = call("GET", resource["authorization_servers"][0].rstrip("/") + "/.well-known/oauth-authorization-server")
    meta = json.loads(raw)
    step("authorization server", s == 200 and "S256" in meta["code_challenge_methods_supported"])

    # 2. Dynamic registration with a loopback callback, as a CLI agent does.
    redirect = "http://127.0.0.1:53682/callback"
    s, _, raw = call("POST", meta["registration_endpoint"], {"client_name": "CandyWrapper smoke agent", "redirect_uris": [redirect]})
    client = json.loads(raw)
    step("register", s in (200, 201) and "client_id" in client, client.get("client_id", raw)[:40])

    # 3. The browser opens authorize; a valid request lands on /connect-agent.
    verifier = secrets.token_urlsafe(48)
    authz = {
        "response_type": "code", "client_id": client["client_id"], "redirect_uri": redirect,
        "code_challenge": base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode(),
        "code_challenge_method": "S256", "state": secrets.token_urlsafe(12), "resource": resource["resource"],
    }
    s, h, _ = call("GET", meta["authorization_endpoint"] + "?" + urllib.parse.urlencode(authz))
    location = {k.lower(): v for k, v in h.items()}.get("location", "")
    step("authorize redirects to the approval page", s in (302, 303, 307) and location.startswith("/connect-agent?"), location[:60])
    print("     approval page: " + base + location)

    # 4. What the page shows (no browser session, so no one-click approval).
    s, _, raw = call("POST", base + "/oauth/mcp/approval", authz)
    details = json.loads(raw)
    step("approval details", s == 200 and details.get("clientName") == "CandyWrapper smoke agent",
         "%s -> %s" % (details.get("environmentHost"), details.get("redirectHost")))

    # 5. A pairing code approves it.
    code = a.code
    if not code:
        s, _, raw = call("POST", base + "/api/auth/pairing-token",
                         {"label": "Outside agent smoke", "scopes": ["orchestration:read", "orchestration:operate"]}, admin)
        step("create pairing code", s == 200, raw[:80] if s != 200 else "")
        code = json.loads(raw)["credential"]
    s, _, raw = call("POST", base + "/oauth/mcp/decision",
                     {"authorization": authz, "decision": {"_tag": "pairing-code", "access": a.access, "code": code}})
    answer = json.loads(raw)
    step("decision", s == 200 and "redirectTo" in answer, raw[:120] if s != 200 else "")
    back = urllib.parse.urlparse(answer["redirectTo"])
    query = dict(urllib.parse.parse_qsl(back.query))
    step("redirect back to the agent", answer["redirectTo"].startswith(redirect) and query.get("state") == authz["state"] and "code" in query)

    # 6. The agent trades the code for a token.
    s, _, raw = call("POST", meta["token_endpoint"], {
        "grant_type": "authorization_code", "code": query["code"], "redirect_uri": redirect,
        "client_id": client["client_id"], "code_verifier": verifier, "resource": resource["resource"],
    }, form=True)
    token = json.loads(raw)
    step("token", s == 200 and token.get("token_type") == "Bearer", "scope " + token.get("scope", raw[:80]))
    bearer = {"authorization": "Bearer " + token["access_token"], "accept": "application/json, text/event-stream"}

    # 7. MCP works with it.
    s, h, raw = call("POST", base + "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "cw-smoke", "version": "1"}}}, bearer)
    step("initialize", s == 200 and "serverInfo" in raw, raw[:100].replace("\n", " "))
    session = {k.lower(): v for k, v in h.items()}.get("mcp-session-id")
    if session:
        bearer["mcp-session-id"] = session
    bearer["mcp-protocol-version"] = "2025-06-18"
    call("POST", base + "/mcp", {"jsonrpc": "2.0", "method": "notifications/initialized"}, bearer)
    s, _, raw = call("POST", base + "/mcp", {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, bearer)
    names = sorted(set(__import__("re").findall(r'"name":"([a-z0-9_]+)"', raw)))
    step("tools/list", s == 200 and "t3_project_list" in names, "%d tools" % len(names))
    s, _, raw = call("POST", base + "/mcp", {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                             "params": {"name": "t3_project_list", "arguments": {}}}, bearer)
    step("t3_project_list", s == 200 and '"isError":true' not in raw, raw[:90].replace("\n", " "))

    # 8. It is listed with the other clients, as a bot named by the agent.
    s, _, raw = call("GET", base + "/api/auth/clients", None, admin)
    mine = [c for c in json.loads(raw) if (c.get("client") or {}).get("label") == "CandyWrapper smoke agent"]
    step("listed in authorized clients", s == 200 and len(mine) >= 1, ", ".join("%s %s" % (c["client"].get("deviceType"), c["scopes"]) for c in mine[-1:]))
    if a.keep:
        open("/tmp/outside-agent-smoke.token", "w").write(token["access_token"])
        print("kept signed in; revoke it in Settings > Connections, then run --check-revoked /tmp/outside-agent-smoke.token")
        return
    for c in mine:
        s, _, raw = call("POST", base + "/api/auth/clients/revoke", {"sessionId": c["sessionId"]}, admin)
        step("revoke " + c["sessionId"][:8], s == 200, raw[:80] if s != 200 else "")
    s, _, _ = call("POST", base + "/mcp", {"jsonrpc": "2.0", "id": 4, "method": "tools/list"}, bearer)
    step("revoked token refused", s == 401)


if __name__ == "__main__":
    main()
