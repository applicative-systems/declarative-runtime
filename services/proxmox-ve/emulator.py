#!/usr/bin/env python3
# Proxmox VE API test double for the declarative-proxmox-ve VM test.
#
# Proxmox VE cannot run inside the sandboxed NixOS test (it needs its own kernel
# and a hypervisor), so — as with the hetzner-dns pairing — we emulate just
# enough of the API for the bpg/proxmox provider to create and read back the
# access-control + pool surface the check exercises (roles, groups, users,
# pools, ACLs). Guest/image resources (vm, download_file, file) are covered by
# the offline references check and the runnable example instead.
#
# Response shapes mirror what the bpg API client unmarshals (see proxmox/access
# and proxmox/pools in the provider): every payload is wrapped in {"data": ...},
# booleans are the Proxmox 1/0 integers, a single role reads back as a
# privilege->1 object, and a single pool reads back as a one-element list under
# ?poolid=. The provider authenticates with a username/password ticket, so the
# ticket endpoint validates the password and later requests only need the
# PVEAuthCookie back.
import json
import os
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

LISTEN = int(os.environ.get("PORT", "8006"))
EXPECTED_PASSWORD = os.environ.get("EXPECTED_PASSWORD") or None
CERT_FILE = os.environ.get("CERT_FILE") or None
KEY_FILE = os.environ.get("KEY_FILE") or None
TICKET = "PVE:root@pam:0123456789ABCDEF"
CSRF = "0123456789:deadbeefdeadbeefdeadbeef"

lock = threading.Lock()
# roleid -> [privilege]
roles = {}
# groupid -> {"comment": str|None}
groups = {}
# userid -> {enable, expire, firstname, lastname, email, comment, groups, keys}
users = {}
# poolid -> {"comment": str|None}
pools = {}
# list of {path, roleid, type, ugid, propagate}
acls = []
# userid -> last password seen on create/update (test-only, to prove the
# LoadCredential-fed secret reached the API end-to-end).
user_passwords = {}


def cbool(v):
    """Render a Python bool as the Proxmox 1/0 integer."""
    return 1 if v else 0


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # keep the test journal quiet
        pass

    # -- response helpers ---------------------------------------------------

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _data(self, data):
        self._send(200, {"data": data})

    def _err(self, code, message):
        self._send(code, {"data": None, "errors": {"message": message}})

    def _body_form(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length).decode() if length else ""
        # values arrive singular; take the last occurrence like a form post.
        return {k: v[-1] for k, v in parse_qs(raw, keep_blank_values=True).items()}

    def _authed(self):
        """Every non-ticket request must carry the PVEAuthCookie the provider got."""
        cookie = self.headers.get("Cookie", "")
        return "PVEAuthCookie=" in cookie

    # -- dispatch -----------------------------------------------------------

    def do_GET(self):
        self._route("GET")

    def do_POST(self):
        self._route("POST")

    def do_PUT(self):
        self._route("PUT")

    def do_DELETE(self):
        self._route("DELETE")

    def _route(self, method):
        parts = urlsplit(self.path)
        path = parts.path
        query = parse_qs(parts.query)
        # strip the API prefix; segments are URL-decoded (user ids carry @/!).
        if path.startswith("/api2/json"):
            path = path[len("/api2/json") :]
        segs = [unquote(s) for s in path.strip("/").split("/") if s]

        try:
            with lock:
                self._dispatch(method, segs, query)
        except BrokenPipeError:
            pass
        except Exception as exc:  # surface emulator bugs in the test journal
            sys.stderr.write("emulator error on %s %s: %r\n" % (method, self.path, exc))
            self._err(500, "emulator error: %r" % exc)

    def _dispatch(self, method, segs, query):
        # health + test-only introspection — unauthenticated.
        if segs == ["healthz"] and method == "GET":
            return self._data("ok")
        if segs == ["debug", "user-password"] and method == "GET":
            uid = query.get("userid", [""])[0]
            return self._data(user_passwords.get(uid))

        # ticket (login) — the only unauthenticated API route.
        if segs == ["access", "ticket"] and method == "POST":
            return self._ticket()

        if segs == ["version"] and method == "GET":
            return self._data({"version": "8.3.0", "release": "8.3", "repoid": "test"})

        if not self._authed():
            return self._err(401, "no ticket")

        # roles ------------------------------------------------------------
        if segs == ["access", "roles"]:
            if method == "GET":
                return self._data(
                    [
                        {"roleid": r, "privs": ",".join(sorted(p)), "special": cbool(False)}
                        for r, p in sorted(roles.items())
                    ]
                )
            if method == "POST":
                f = self._body_form()
                privs = [p for p in f.get("privs", "").split(",") if p]
                roles[f["roleid"]] = privs
                return self._data(None)
        if len(segs) == 3 and segs[:2] == ["access", "roles"]:
            rid = segs[2]
            if method == "GET":
                if rid not in roles:
                    return self._err(500, "role '%s' does not exist" % rid)
                return self._data({p: 1 for p in roles[rid]})
            if method == "PUT":
                f = self._body_form()
                privs = [p for p in f.get("privs", "").split(",") if p]
                roles[rid] = privs
                return self._data(None)
            if method == "DELETE":
                roles.pop(rid, None)
                return self._data(None)

        # groups -----------------------------------------------------------
        if segs == ["access", "groups"]:
            if method == "GET":
                return self._data(
                    [{"groupid": g, "comment": v["comment"]} for g, v in sorted(groups.items())]
                )
            if method == "POST":
                f = self._body_form()
                groups[f["groupid"]] = {"comment": f.get("comment")}
                return self._data(None)
        if len(segs) == 3 and segs[:2] == ["access", "groups"]:
            gid = segs[2]
            if method == "GET":
                if gid not in groups:
                    return self._err(500, "group '%s' does not exist" % gid)
                members = sorted(u for u, uv in users.items() if gid in uv["groups"])
                return self._data({"comment": groups[gid]["comment"], "members": members})
            if method == "PUT":
                f = self._body_form()
                groups[gid]["comment"] = f.get("comment")
                return self._data(None)
            if method == "DELETE":
                groups.pop(gid, None)
                return self._data(None)

        # users ------------------------------------------------------------
        if segs == ["access", "password"] and method == "PUT":
            f = self._body_form()
            if f.get("userid") and "password" in f:
                user_passwords[f["userid"]] = f["password"]
            return self._data(None)  # password change; nothing to read back
        if segs == ["access", "users"]:
            if method == "GET":
                return self._data([self._user_view(u, uid) for uid, u in sorted(users.items())])
            if method == "POST":
                f = self._body_form()
                if "password" in f:
                    user_passwords[f["userid"]] = f["password"]
                users[f["userid"]] = self._user_from_form(f)
                return self._data(None)
        if len(segs) == 3 and segs[:2] == ["access", "users"]:
            uid = segs[2]
            if method == "GET":
                if uid not in users:
                    return self._err(500, "user '%s' does not exist" % uid)
                return self._data(self._user_view(users[uid], None))
            if method == "PUT":
                f = self._body_form()
                if "password" in f:
                    user_passwords[uid] = f["password"]
                users[uid] = self._user_from_form(f, base=users.get(uid, {}))
                return self._data(None)
            if method == "DELETE":
                users.pop(uid, None)
                return self._data(None)

        # pools ------------------------------------------------------------
        if segs == ["pools"]:
            if method == "GET" and "poolid" in query:
                pid = query["poolid"][0]
                if pid not in pools:
                    return self._data([])
                return self._data([{"comment": pools[pid]["comment"], "members": []}])
            if method == "GET":
                return self._data(
                    [{"poolid": p, "comment": v["comment"]} for p, v in sorted(pools.items())]
                )
            if method == "POST":
                f = self._body_form()
                pools[f["poolid"]] = {"comment": f.get("comment")}
                return self._data(None)
            if method == "PUT" and "poolid" in query:
                pid = query["poolid"][0]
                f = self._body_form()
                if "comment" in f:
                    pools.setdefault(pid, {})["comment"] = f.get("comment")
                return self._data(None)
            if method == "DELETE" and "poolid" in query:
                pools.pop(query["poolid"][0], None)
                return self._data(None)

        # acl --------------------------------------------------------------
        if segs == ["access", "acl"]:
            if method == "GET":
                return self._data(sorted(acls, key=lambda e: e["path"]))
            if method == "PUT":
                return self._acl_update(self._body_form())

        sys.stderr.write("emulator: no route for %s /%s\n" % (method, "/".join(segs)))
        return self._err(404, "no route %s /%s" % (method, "/".join(segs)))

    # -- handlers -----------------------------------------------------------

    def _ticket(self):
        f = self._body_form()
        if EXPECTED_PASSWORD is not None and f.get("password") != EXPECTED_PASSWORD:
            return self._err(401, "authentication failure")
        return self._data(
            {
                "ticket": TICKET,
                "CSRFPreventionToken": CSRF,
                "username": f.get("username", "root@pam"),
            }
        )

    def _user_from_form(self, f, base=None):
        u = dict(base or {})
        u.setdefault("groups", [])
        if "enable" in f:
            u["enable"] = f["enable"] in ("1", "true")
        if "expire" in f:
            u["expire"] = int(f["expire"])
        for k_api, k in (
            ("firstname", "firstname"),
            ("lastname", "lastname"),
            ("email", "email"),
            ("comment", "comment"),
            ("keys", "keys"),
        ):
            if k_api in f:
                u[k] = f[k_api]
        if "groups" in f:
            u["groups"] = [g for g in f["groups"].split(",") if g]
        return u

    def _user_view(self, u, uid):
        out = {}
        if uid is not None:
            out["userid"] = uid
        if "enable" in u:
            out["enable"] = cbool(u["enable"])
        if "expire" in u:
            out["expire"] = u["expire"]
        for k in ("comment", "email", "firstname", "lastname", "keys"):
            if u.get(k) is not None:
                out[k] = u[k]
        out["groups"] = sorted(u.get("groups", []))
        return out

    def _acl_update(self, f):
        path = f["path"]
        roleids = [r for r in f.get("roles", "").split(",") if r]
        propagate = f.get("propagate", "1") in ("1", "true")
        delete = f.get("delete") in ("1", "true")
        subjects = (
            [("user", s) for s in f.get("users", "").split(",") if s]
            + [("group", s) for s in f.get("groups", "").split(",") if s]
            + [("token", s) for s in f.get("tokens", "").split(",") if s]
        )
        for roleid in roleids:
            for typ, ugid in subjects:
                match = lambda e: (
                    e["path"] == path
                    and e["roleid"] == roleid
                    and e["type"] == typ
                    and e["ugid"] == ugid
                )
                acls[:] = [e for e in acls if not match(e)]
                if not delete:
                    acls.append(
                        {
                            "path": path,
                            "roleid": roleid,
                            "type": typ,
                            "ugid": ugid,
                            "propagate": cbool(propagate),
                        }
                    )
        return self._data(None)


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", LISTEN), H)
    if CERT_FILE and KEY_FILE:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(certfile=CERT_FILE, keyfile=KEY_FILE)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        sys.stderr.write("emulator listening on https://127.0.0.1:%d\n" % LISTEN)
    else:
        sys.stderr.write("emulator listening on http://127.0.0.1:%d\n" % LISTEN)
    srv.serve_forever()
