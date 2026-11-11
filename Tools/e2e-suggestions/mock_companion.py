"""A local stand-in for the Companion routes Ollie's suggestions use, for end-to-end tests.

Serves the base page (sets XSRF-TOKEN like Laravel), /api/oo/portfolio, /api/oo/approvals,
the per-shop strategy-manager read and its writes, and /api/oo/approvals/answer. Every request
is appended to requests.jsonl with whether the X-XSRF-TOKEN header matched the cookie.
Test controls: GET /__state, POST /__draft {"apply_text": ...}, POST /__reset.
"""
import copy
import json
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
LOG = sys.argv[2] if len(sys.argv) > 2 else "/tmp/ollie-e2e/requests.jsonl"
# Laravel's real cookie value is URL-encoded base64-ish JSON; keep characters that must be decoded.
TOKEN = "eyJpdiI6IkUyRSJ9+/=="
SM_SHOP = "res-sm-1"
OTHER = "res-plain-2"
LOCK = threading.RLock()

INITIAL = {
    "strategy": {
        "agent": {"principal": "p1", "name": "Strategy Manager", "role": "strategy-manager"},
        "month": "November", "period": "2026-11-01",
        "draft": {"display": "For E2E Beauty this month, I'd recommend GMV $26,000 (projecting this month's pace through 7 Nov).",
                  "apply_text": "GMV $26,000 this month."},
        "statement": None,
        "check": {"recommendations": [
            {"key": "hero_out_of_stock:1", "title": "Restock Glow Primer (1.35 fl oz) – Silicone-Free Grip Base, Serum Texture or choose another hero product",
             "reason": "Glow Primer (1.35 fl oz) – Silicone-Free Grip Base, Serum Texture is this month's hero product and shows as unavailable (checked 9 Nov).",
             "to_role": "account-manager", "to_name": "Amber Lee (account manager)", "via": "ask", "handed": None, "dismissed": False},
            {"key": "samples_underused:2026-11-09", "title": "Raise the outreach daily limit from 20 to 30",
             "reason": "8 of 28 samples sent this week, 16 expected by now, with 3 days left.",
             "to_role": "creator-manager", "to_name": "Creator Manager", "via": "handoff", "handed": None, "dismissed": False},
        ]},
    },
    "approvals": [
        # The real agent-ask shape (AgentOpenWorkSource): answers change/skip, recommendation text only, no value.
        {"id": "ap-1", "source": "agent_ask", "kind": "brief_value", "question": "Which brief should this week's outreach use?",
         "agent": {"label": "Creator Manager"}, "version": "v1", "can_answer": True, "answers": ["change", "skip"],
         "recommendation": {"text": "Use the spring brief"}, "mine": True, "age_seconds": 3600},
        {"id": "ap-2", "source": "send_approval", "kind": "creator_message", "question": "Send this message to @creator?",
         "agent": {"label": "Creator Manager"}, "version": "v1", "send_version": "s1", "can_answer": True, "answers": ["approve", "skip"],
         "recommendation": {"text": "Looks right.", "value": "approve"}, "mine": True,
         "evidence": [{"label": "Recipient", "text": "@creator"}, {"label": "Message to send", "text": "Hi!"}]},
        {"id": "ap-3", "source": "agent_ask", "kind": "budget", "question": "Raise the ad budget to $6k?",
         "agent": {"label": "Ads Manager"}, "version": "v1", "can_answer": True, "answers": ["approve", "skip"],
         "recommendation": {"text": "ROAS is above floor.", "value": "approve"}, "mine": False},
    ],
}
STATE = copy.deepcopy(INITIAL)
AUTH = {"ok": True}


def portfolio():
    def shop(resource, name, sm):
        return {"resource": resource, "name": name, "display_name": name,
                "gmv": {"mtd": 6273.0, "currency": "USD", "goal": 40000.0, "pace_status": "behind", "basis": "shop"},
                "agents": [{"role": "strategy-manager", "on": True}] if sm else [{"role": "creator-manager", "on": True}],
                "needs_you": {"total": 1}}
    shops = [shop(SM_SHOP, "E2E Beauty", True)] + [shop(f"{OTHER}-{i}", f"Plain Shop {i}", False) for i in range(14)]
    return {"viewer": {"kind": "staff", "default_scope": "all", "scopes": {"all": len(shops)}}, "shops": shops}


def approvals():
    items = STATE["approvals"]
    return {"shops": [{"resource": SM_SHOP, "name": "E2E Beauty",
                       "services": [{"role": "creator-manager", "label": "Creator Manager", "items": items}]}],
            "order": [i["id"] for i in items], "counts": {"pending": len(items), "mine": sum(1 for i in items if i.get("mine"))}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _cookie_token(self):
        for part in (self.headers.get("Cookie") or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == "XSRF-TOKEN":
                return urllib.parse.unquote(v)
        return None

    def _log(self, body, status):
        entry = {"method": self.command, "path": self.path, "status": status,
                 "xsrf_ok": self.headers.get("X-XSRF-TOKEN") == TOKEN and self._cookie_token() == TOKEN,
                 "body": body}
        with LOCK, open(LOG, "a") as fh:
            fh.write(json.dumps(entry) + "\n")

    def _send(self, status, obj=None, html=None, body_in=None):
        self._log(body_in, status)
        payload = (html if html is not None else json.dumps(obj)).encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html" if html is not None else "application/json")
        self.send_header("Set-Cookie", f"XSRF-TOKEN={urllib.parse.quote(TOKEN, safe='')}; Path=/")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        with LOCK:
            return self._get()

    def _get(self):
        path = urllib.parse.unquote(urllib.parse.urlparse(self.path).path)
        if path.startswith("/api/") and not AUTH["ok"]:
            return self._send(401, {"message": "Unauthenticated."})
        if path == "/api/oo/portfolio":
            return self._send(200, portfolio())
        if path == "/api/oo/approvals":
            return self._send(200, approvals())
        if path == f"/api/oo/shops/{SM_SHOP}/strategy-manager":
            return self._send(200, STATE["strategy"])
        if path.startswith("/api/oo/shops/") and path.endswith("/strategy-manager"):
            return self._send(200, {"agent": None, "period": "2026-11-01", "draft": None, "check": None})
        if path == "/__state":
            return self._send(200, STATE)
        if path.startswith("/api/"):
            return self._send(404, {"message": "not mocked"})
        return self._send(200, html="<!doctype html><title>E2E Companion</title><p>ok</p>")

    def do_POST(self):
        with LOCK:
            return self._post()

    def _post(self):
        path = urllib.parse.unquote(urllib.parse.urlparse(self.path).path)
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}"
        try:
            body = json.loads(raw)
        except ValueError:
            body = {"raw": raw.decode(errors="replace")}
        if path == "/__reset":
            STATE.clear(); STATE.update(copy.deepcopy(INITIAL)); AUTH["ok"] = True
            return self._send(200, {"ok": True}, body_in=body)
        if path == "/__auth":
            AUTH["ok"] = bool(body.get("ok"))
            return self._send(200, {"ok": True}, body_in=body)
        if path == "/__drop":
            STATE["strategy"]["check"]["recommendations"] = [r for r in STATE["strategy"]["check"]["recommendations"] if r["key"] != body["key"]]
            return self._send(200, {"ok": True}, body_in=body)
        if path == "/__token":
            global TOKEN
            TOKEN = body["token"]
            return self._send(200, {"ok": True}, body_in=body)
        if path == "/__draft":
            STATE["strategy"]["draft"]["apply_text"] = body["apply_text"]
            return self._send(200, {"ok": True}, body_in=body)
        if not (self.headers.get("X-XSRF-TOKEN") == TOKEN and self._cookie_token() == TOKEN):
            return self._send(419, {"message": "CSRF token mismatch."}, body_in=body)
        base = f"/api/oo/shops/{SM_SHOP}/strategy-manager"
        s = STATE["strategy"]
        if path == base + "/statements":
            # Like the real route: any valid text applies; freshness is the client's job.
            if not isinstance(body.get("text"), str) or len(body["text"]) < 3:
                return self._send(422, {"message": "The text field is required."}, body_in=body)
            s["statement"] = {"text": body["text"]}
            s["draft"] = None
            return self._send(201, s, body_in=body)
        if path.startswith(base + "/recommendations/"):
            key, action = path[len(base + "/recommendations/"):].rsplit("/", 1)
            if key == "statement_draft:" + s["period"] and action == "dismiss":
                s["draft"] = None
                return self._send(200, s, body_in=body)
            rec = next((r for r in s["check"]["recommendations"] if r["key"] == key), None)
            if rec is None:
                return self._send(404, {"message": "This recommendation is no longer current."}, body_in=body)
            if action == "apply":
                rec["handed"] = {"status": "open", "via": rec["via"], "handoff_id": "staff:e2e"}
            elif action == "dismiss":
                rec["dismissed"] = True
            return self._send(200, s, body_in=body)
        if path == "/api/oo/approvals/answer":
            results = []
            for row in body.get("items", []):
                item = next((a for a in STATE["approvals"] if a["id"] == row.get("id")), None)
                if item is None or item.get("version") != row.get("version") or item.get("send_version") != row.get("send_version") \
                        or body.get("answer") not in item.get("answers", []):
                    results.append({"id": row.get("id"), "status": "stale"})
                    continue
                STATE["approvals"].remove(item)
                results.append({"id": row.get("id"), "status": "ok"})
            return self._send(200, {"results": results}, body_in=body)
        return self._send(404, {"message": "not mocked"}, body_in=body)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
