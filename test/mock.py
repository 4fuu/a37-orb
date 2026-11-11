#!/usr/bin/env python3
"""Mock Agent37 Sandbox API for regression-testing the a37-orb scripts.

Control plane and exec plane on one port (default 8232). State is mirrored to
$A37_MOCK_STATE so run.sh can assert on it.

pgrep commands are simulated with real-world semantics: the sh -c wrapper that
runs `pgrep -f 'PATTERN'` has PATTERN in its own command line, so an unbracketed
pattern always self-matches. A bracketed pattern ([a]mp ...) does not. This is
what caught the "bootstrap already running on a fresh container" bug.
"""
import json
import os
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

STATE_PATH = os.environ.get("A37_MOCK_STATE", "/tmp/a37-orb-test-state.json")

STATE = {
    "templates": {
        "amp-orb": {
            "name": "amp-orb", "scope": "workspace", "revision": 1,
            "image_ref": "us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb:latest",
            "image_digest": "sha256:OLD",
            "entrypoint": ["sleep", "infinity"],
            "revisions": [{"revision": 1, "image_digest": "sha256:OLD", "created": 1}],
        }
    },
    "instances": {},
    "exec_log": [],
    "create_count": 0,
    "patch_count": 0,
    "update_count": 0,
    "resize_log": [],
    "bootstrap": {},
    "next_id": 1,
}
KEY = "sk_live_TESTKEY"


def dump():
    with open(STATE_PATH, "w") as f:
        json.dump(STATE, f, indent=1)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body):
        b = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def authed(self):
        h = self.headers.get("Authorization", "")
        k = self.headers.get("X-Agent37-Key", "")
        return h == f"Bearer {KEY}" or k == KEY

    def body(self):
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        if not self.authed():
            return self.reply(401, {"error": {"code": "unauthorized"}})
        p = urlparse(self.path).path
        if p == "/v1/templates":
            return self.reply(200, {"data": list(STATE["templates"].values())})
        m = re.fullmatch(r"/v1/templates/([^@]+)", p)
        if m and m.group(1) in STATE["templates"]:
            return self.reply(200, STATE["templates"][m.group(1)])
        if m:
            return self.reply(404, {"error": {"code": "not_found"}})
        if p == "/v1/instances":
            if os.path.exists("/tmp/a37-orb-test-flaky"):
                os.unlink("/tmp/a37-orb-test-flaky")
                return self.reply(503, {"error": {"code": "try_again"}})
            return self.reply(200, {"data": list(STATE["instances"].values())})
        m = re.fullmatch(r"/v1/instances/([a-z0-9]+)", p)
        if m:
            inst = STATE["instances"].get(m.group(1))
            if inst is None:
                return self.reply(404, {"error": {"code": "not_found"}})
            return self.reply(200, inst)
        return self.reply(404, {"error": {"code": "not_found"}})

    def do_POST(self):
        if not self.authed():
            return self.reply(401, {"error": {"code": "unauthorized"}})
        p = urlparse(self.path).path
        b = self.body()
        if p == "/v1/templates":
            name = b.get("name")
            if name in STATE["templates"]:
                return self.reply(409, {"error": {"code": "template_conflict"}})
            ref = b.get("image_ref", "")
            tpl = {
                "name": name, "scope": "workspace", "revision": 1,
                "image_ref": ref,
                "image_digest": "sha256:" + ref.split("sha256:")[-1],
                "entrypoint": b.get("entrypoint"),
                "revisions": [{"revision": 1, "image_digest": "", "created": time.time()}],
            }
            STATE["templates"][name] = tpl
            dump()
            return self.reply(201, tpl)
        m = re.fullmatch(r"/v1/instances/([a-z0-9]+)/(start|stop|update|resize)", p)
        if m:
            inst = STATE["instances"].get(m.group(1))
            if inst is None:
                return self.reply(404, {"error": {"code": "not_found"}})
            op = m.group(2)
            if op == "start":
                inst["status"] = "running"
                STATE["bootstrap"][inst["id"]] = False  # fresh container
            elif op == "stop":
                inst["status"] = "stopped"
            elif op == "update":
                tpl = STATE["templates"][inst["template"].split("@")[0]]
                inst["template_revision"] = tpl["revision"]
                inst["image_digest"] = tpl["image_digest"]
                STATE["update_count"] += 1
                dump()
                return self.reply(200, {"id": inst["id"], "status": inst["status"],
                                        "image_ref": tpl["image_ref"],
                                        "image_digest": tpl["image_digest"],
                                        "template_revision": tpl["revision"]})
            elif op == "resize":
                inst["resources"]["disk"] = b["resources"]["disk"]
                STATE["resize_log"].append((inst["id"], b["resources"]["disk"]))
            dump()
            return self.reply(200, {"id": inst["id"], "status": inst["status"],
                                    "resources": inst["resources"]})
        if p == "/v1/instances":
            tpl = STATE["templates"].get(b.get("template", "").split("@")[0])
            if tpl is None:
                return self.reply(400, {"error": {"code": "invalid_request"}})
            iid = "i%d" % STATE["next_id"]
            STATE["next_id"] += 1
            STATE["create_count"] += 1
            STATE["bootstrap"][iid] = False
            inst = {
                "id": iid, "status": "running", "status_reason": None,
                "template": b.get("template"), "template_revision": tpl["revision"],
                "image_ref": tpl["image_ref"], "image_digest": tpl["image_digest"],
                "type": b.get("type", "default"), "region": b.get("region", "us"),
                "mount_path": b.get("mount_path"),
                "resources": b.get("resources", {"cpu": 2, "memory": 4, "disk": 4}),
                "url": f"https://{iid}.agent37.app", "name": b.get("name"),
                "metadata": b.get("metadata"), "created": time.time(),
            }
            STATE["instances"][iid] = inst
            dump()
            return self.reply(201, inst)
        m = re.fullmatch(r"/v1/instances/([a-z0-9]+)/exec", p)
        if m:
            iid = m.group(1)
            inst = STATE["instances"].get(iid)
            if inst is None or inst["status"] not in ("running", "sleeping"):
                return self.reply(404, {"error": "not_found"})
            cmd = b.get("command", "")
            STATE["exec_log"].append((iid, cmd))
            out, ec = "", 0
            if cmd.startswith("pgrep"):
                # Real pgrep -f semantics: the sh -c wrapper running this very
                # command has the pattern text in its own cmdline, so an
                # unbracketed pattern self-matches even on a fresh container.
                m2 = re.search(r"pgrep -f '([^']+)'", cmd)
                pattern = m2.group(1) if m2 else ""
                self_match = "]" not in pattern
                ec = 0 if (STATE["bootstrap"].get(iid) or self_match) else 1
            elif "amp orb bootstrap" in cmd and cmd.startswith("export "):
                STATE["bootstrap"][iid] = True
                out = "bootstrap started"
            elif cmd.startswith("df "):
                disk = inst["resources"]["disk"]
                pct = 95 if disk < 10 else 55
                used = int(disk * 1024 * 1024 * pct / 100)
                free_kb = disk * 1024 * 1024 - used
                out = f"overlay {disk*1024*1024} {used} {free_kb} {pct}% {inst['mount_path']}"
            elif cmd.startswith("tail"):
                out = "mock bootstrap log"
            dump()
            return self.reply(200, {"exit_code": ec, "stdout": out, "stderr": "",
                                    "truncated": False})
        return self.reply(404, {"error": "not_found"})

    def do_PATCH(self):
        if not self.authed():
            return self.reply(401, {"error": {"code": "unauthorized"}})
        p = urlparse(self.path).path
        m = re.fullmatch(r"/v1/templates/([^@]+)", p)
        if not m or m.group(1) not in STATE["templates"]:
            return self.reply(404, {"error": {"code": "not_found"}})
        b = self.body()
        tpl = STATE["templates"][m.group(1)]
        changed = False
        if "image_ref" in b and b["image_ref"] != tpl["image_ref"]:
            tpl["image_ref"] = b["image_ref"]
            tpl["image_digest"] = "sha256:" + b["image_ref"].split("sha256:")[-1]
            tpl["revision"] += 1
            tpl.setdefault("revisions", []).insert(
                0, {"revision": tpl["revision"], "image_digest": tpl["image_digest"],
                    "created": time.time()})
            STATE["patch_count"] += 1
            changed = True
        if "entrypoint" in b:
            tpl["entrypoint"] = b["entrypoint"]
            if not changed:
                tpl["revision"] += 1
        dump()
        return self.reply(200, tpl)

    def do_DELETE(self):
        if not self.authed():
            return self.reply(401, {"error": {"code": "unauthorized"}})
        p = urlparse(self.path).path
        m = re.fullmatch(r"/v1/instances/([a-z0-9]+)", p)
        if not m:
            return self.reply(404, {"error": {"code": "not_found"}})
        if m.group(1) not in STATE["instances"]:
            return self.reply(404, {"error": {"code": "not_found"}})
        del STATE["instances"][m.group(1)]
        STATE["bootstrap"].pop(m.group(1), None)
        dump()
        return self.reply(200, {"id": m.group(1), "deleted": True})


if __name__ == "__main__":
    dump()
    ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("A37_MOCK_PORT", "8232"))),
                        H).serve_forever()
