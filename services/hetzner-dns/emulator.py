#!/usr/bin/env python3
import json, os, re, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EXPECTED_TOKEN = os.environ.get("EXPECTED_TOKEN") or None
LISTEN = int(os.environ.get("PORT", "8080"))

lock = threading.Lock()
zones = {}
name_to_id = {}
rrsets = {}
seq = {"zone": 0, "action": 0}
NOW = "2024-01-01T00:00:00+00:00"


def next_id(kind):
    seq[kind] += 1
    return seq[kind]


def action(command):
    return {
        "id": next_id("action"),
        "status": "success",
        "command": command,
        "progress": 100,
        "started": NOW,
        "finished": NOW,
        "error": None,
        "resources": [],
    }


def resolve_zone(id_or_name):
    if id_or_name in name_to_id:
        return name_to_id[id_or_name]
    try:
        zid = int(id_or_name)
    except ValueError:
        return None
    return zid if zid in zones else None


def zone_view(z):
    return {
        "id": z["id"],
        "name": z["name"],
        "created": NOW,
        "ttl": z["ttl"],
        "mode": z["mode"],
        "primary_nameservers": z["primary_nameservers"],
        "protection": {"delete": z["delete"]},
        "labels": z["labels"],
        "authoritative_nameservers": {
            "assigned": ["hydrogen.ns.hetzner.com"],
            "delegated": [],
            "delegation_last_check": None,
            "delegation_status": "unregistered",
        },
        "registrar": "unknown",
        "status": "ok",
        "record_count": sum(
            1 for k in rrsets if k[0] == z["id"]
        ),
    }


def rrset_view(r):
    return {
        "id": f'{r["name"]}/{r["type"]}',
        "name": r["name"],
        "type": r["type"],
        "ttl": r["ttl"],
        "labels": r["labels"],
        "protection": {"change": r["change"]},
        "records": r["records"],
        "zone": r["zone_id"],
    }


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        sys.stderr.write("EMU %s %s\n" % (self.command, self.path))

    def _send(self, code, body):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def _err(self, code, ecode, msg):
        self._send(code, {"error": {"code": ecode, "message": msg}})

    def _body(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        if not n:
            return {}
        return json.loads(self.rfile.read(n) or b"{}")

    def _auth_ok(self):
        if EXPECTED_TOKEN is None:
            return True
        got = self.headers.get("Authorization", "")
        return got == f"Bearer {EXPECTED_TOKEN}"

    def _path(self):
        p = self.path.split("?", 1)[0]
        if p.startswith("/v1"):
            p = p[3:]
        return p.rstrip("/") or "/"

    def do_GET(self):
        p = self._path()
        if p == "/healthz":
            return self._send(200, {"ok": True})
        if not self._auth_ok():
            return self._err(401, "unauthorized", "invalid token")
        with lock:
            self._route_get(p)

    def do_POST(self):
        if not self._auth_ok():
            return self._err(401, "unauthorized", "invalid token")
        with lock:
            self._route_post(self._path(), self._body())

    def do_PUT(self):
        if not self._auth_ok():
            return self._err(401, "unauthorized", "invalid token")
        with lock:
            self._route_put(self._path(), self._body())

    def do_DELETE(self):
        if not self._auth_ok():
            return self._err(401, "unauthorized", "invalid token")
        with lock:
            self._route_delete(self._path())

    def _route_get(self, p):
        m = re.fullmatch(r"/zones", p)
        if m:
            return self._send(200, {"zones": [zone_view(z) for z in zones.values()],
                                    "meta": {"pagination": {"page": 1, "per_page": 50, "next_page": None, "total_entries": len(zones)}}})
        m = re.fullmatch(r"/zones/([^/]+)/rrsets", p)
        if m:
            zid = resolve_zone(m.group(1))
            rs = [rrset_view(r) for k, r in rrsets.items() if k[0] == zid]
            return self._send(200, {"rrsets": rs,
                                    "meta": {"pagination": {"page": 1, "per_page": 50, "next_page": None, "total_entries": len(rs)}}})
        m = re.fullmatch(r"/zones/([^/]+)/rrsets/([^/]+)/([^/]+)", p)
        if m:
            zid = resolve_zone(m.group(1))
            r = rrsets.get((zid, m.group(2), m.group(3)))
            if r is None:
                return self._err(404, "not_found", "rrset not found")
            return self._send(200, {"rrset": rrset_view(r)})
        m = re.fullmatch(r"/zones/([^/]+)", p)
        if m:
            zid = resolve_zone(m.group(1))
            if zid is None:
                return self._err(404, "not_found", "zone not found")
            return self._send(200, {"zone": zone_view(zones[zid])})
        m = re.fullmatch(r"/actions/(\d+)", p)
        if m:
            return self._send(200, {"action": action("noop")})
        if p == "/actions":
            return self._send(200, {"actions": [], "meta": {"pagination": {"page": 1, "per_page": 50, "next_page": None, "total_entries": 0}}})
        return self._err(404, "not_found", "no route %s" % p)

    def _route_post(self, p, body):
        m = re.fullmatch(r"/zones", p)
        if m:
            zid = next_id("zone")
            z = {
                "id": zid,
                "name": body["name"],
                "mode": body.get("mode", "primary"),
                "ttl": body.get("ttl") if body.get("ttl") is not None else 3600,
                "labels": body.get("labels") or {},
                "delete": False,
                "primary_nameservers": body.get("primary_nameservers") or [],
            }
            zones[zid] = z
            name_to_id[z["name"]] = zid
            return self._send(201, {"zone": zone_view(z), "action": action("create_zone")})
        m = re.fullmatch(r"/zones/([^/]+)/rrsets", p)
        if m:
            zid = resolve_zone(m.group(1))
            if zid is None:
                return self._err(404, "not_found", "zone not found")
            r = {
                "zone_id": zid,
                "name": body["name"],
                "type": body["type"],
                "ttl": body.get("ttl"),
                "labels": body.get("labels") or {},
                "change": False,
                "records": body.get("records") or [],
            }
            rrsets[(zid, r["name"], r["type"])] = r
            return self._send(201, {"rrset": rrset_view(r), "action": action("create_rrset")})
        m = re.fullmatch(r"/zones/([^/]+)/actions/(\w+)", p)
        if m:
            zid = resolve_zone(m.group(1))
            act = m.group(2)
            z = zones.get(zid)
            if z is None:
                return self._err(404, "not_found", "zone not found")
            if act == "change_protection" and "delete" in body:
                z["delete"] = bool(body["delete"])
            elif act == "change_ttl":
                z["ttl"] = body["ttl"]
            elif act == "change_primary_nameservers":
                z["primary_nameservers"] = body.get("primary_nameservers") or []
            return self._send(201, {"action": action(act)})
        m = re.fullmatch(r"/zones/([^/]+)/rrsets/([^/]+)/([^/]+)/actions/(\w+)", p)
        if m:
            zid = resolve_zone(m.group(1))
            name, typ, act = m.group(2), m.group(3), m.group(4)
            key = (zid, name, typ)
            r = rrsets.get(key)
            if act in ("add_records",) and r is None:
                # add_records implicitly creates the rrset (zone_record path)
                r = {"zone_id": zid, "name": name, "type": typ, "ttl": body.get("ttl"),
                     "labels": {}, "change": False, "records": []}
                rrsets[key] = r
            if r is None:
                return self._err(404, "not_found", "rrset not found")
            if act == "set_records":
                r["records"] = body.get("records") or []
            elif act == "add_records":
                have = {(x["value"]) for x in r["records"]}
                for rec in body.get("records") or []:
                    if rec["value"] not in have:
                        r["records"].append(rec)
                if body.get("ttl") is not None:
                    r["ttl"] = body["ttl"]
            elif act == "update_records":
                for rec in body.get("records") or []:
                    for x in r["records"]:
                        if x["value"] == rec["value"]:
                            x["comment"] = rec.get("comment", "")
            elif act == "remove_records":
                vals = {x["value"] for x in (body.get("records") or [])}
                r["records"] = [x for x in r["records"] if x["value"] not in vals]
            elif act == "change_protection" and "change" in body:
                r["change"] = bool(body["change"])
            elif act == "change_ttl":
                r["ttl"] = body.get("ttl")
            return self._send(201, {"action": action(act)})
        return self._err(404, "not_found", "no route %s" % p)

    def _route_put(self, p, body):
        m = re.fullmatch(r"/zones/([^/]+)/rrsets/([^/]+)/([^/]+)", p)
        if m:
            zid = resolve_zone(m.group(1))
            r = rrsets.get((zid, m.group(2), m.group(3)))
            if r is None:
                return self._err(404, "not_found", "rrset not found")
            if "labels" in body and body["labels"] is not None:
                r["labels"] = body["labels"]
            return self._send(200, {"rrset": rrset_view(r)})
        m = re.fullmatch(r"/zones/([^/]+)", p)
        if m:
            zid = resolve_zone(m.group(1))
            if zid is None:
                return self._err(404, "not_found", "zone not found")
            z = zones[zid]
            if "labels" in body and body["labels"] is not None:
                z["labels"] = body["labels"]
            return self._send(200, {"zone": zone_view(z)})
        return self._err(404, "not_found", "no route %s" % p)

    def _route_delete(self, p):
        m = re.fullmatch(r"/zones/([^/]+)/rrsets/([^/]+)/([^/]+)", p)
        if m:
            zid = resolve_zone(m.group(1))
            rrsets.pop((zid, m.group(2), m.group(3)), None)
            return self._send(200, {"action": action("delete_rrset")})
        m = re.fullmatch(r"/zones/([^/]+)", p)
        if m:
            zid = resolve_zone(m.group(1))
            if zid is not None:
                z = zones.pop(zid, None)
                if z:
                    name_to_id.pop(z["name"], None)
                for k in [k for k in rrsets if k[0] == zid]:
                    rrsets.pop(k, None)
            return self._send(200, {"action": action("delete_zone")})
        return self._err(404, "not_found", "no route %s" % p)


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", LISTEN), H)
    sys.stderr.write("emulator listening on %d\n" % LISTEN)
    srv.serve_forever()
