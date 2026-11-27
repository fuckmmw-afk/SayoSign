#!/usr/bin/env python3
"""SayoSign remote signing server.

The app uploads what the server does not have yet (the IPA, tweaks, the hook framework) as
content-addressed blobs, then posts a job: certificate, profile, options and references to
those blobs or to URLs the server fetches itself. The signed IPA and an itms-services manifest
are served by nginx from OUT_DIR/<random token>/ for a limited time.

Key material only lives in memory and in the job's temporary folder while it is signed.

Environment:
  SAYOSIGN_TOKEN     shared secret, sent by the app as "Authorization: Bearer <token>" (required)
  SAYOSIGN_PUBLIC    public base URL of OUT_DIR, e.g. https://example.com/sign/out
  SAYOSIGN_BIN       path of the `sayosign` CLI built from this repository
  SAYOSIGN_DATA      state folder (blobs, jobs, tmp)
  SAYOSIGN_OUT       folder nginx serves as SAYOSIGN_PUBLIC
  SAYOSIGN_LISTEN    host:port, default 127.0.0.1:8799
  SAYOSIGN_LOCAL     optional "https://host/prefix/=/local/dir/" pairs separated by ";": URLs under
                     a prefix are read from disk instead of downloaded
"""

import base64
import hashlib
import hmac
import json
import os
import plistlib
import queue
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
import traceback
import urllib.parse
import urllib.request
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.0"
TOKEN = os.environ.get("SAYOSIGN_TOKEN", "")
PUBLIC = os.environ.get("SAYOSIGN_PUBLIC", "").rstrip("/")
BIN = os.environ.get("SAYOSIGN_BIN", "/opt/sayosign-server/bin/sayosign")
DATA = os.environ.get("SAYOSIGN_DATA", "/var/lib/sayosign-server")
OUT = os.environ.get("SAYOSIGN_OUT", "/var/www/sign/out")
LISTEN = os.environ.get("SAYOSIGN_LISTEN", "127.0.0.1:8799")
LOCAL = [tuple(p.split("=", 1)) for p in os.environ.get("SAYOSIGN_LOCAL", "").split(";") if "=" in p]

BLOBS = os.path.join(DATA, "blobs")
JOBS = os.path.join(DATA, "jobs")
TMP = os.path.join(DATA, "tmp")

OUT_TTL = 24 * 3600          # signed IPAs stay downloadable this long
BLOB_TTL = 7 * 24 * 3600     # uploads are reused this long after their last use (by checksum)
BLOB_CAP = 3 * 1024 ** 3     # and the cache is trimmed to this size
OUT_CAP = 4 * 1024 ** 3
MAX_UPLOAD = 6 * 1024 ** 3
MIN_FREE = 1024 ** 3         # keep this much disk free after a job

SHA_RE = re.compile(r"^[0-9a-f]{64}$")
SAFE_NAME = re.compile(r"^[^/\\\x00]{1,200}$")

for d in (BLOBS, JOBS, TMP, OUT):
    os.makedirs(d, exist_ok=True)

jobs = {}
jobs_lock = threading.Lock()
_upload_locks = {}


def upload_lock(sha):
    with jobs_lock:
        return _upload_locks.setdefault(sha, threading.Lock())
work = queue.Queue()


def log(*a):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), *a, file=sys.stderr, flush=True)


class JobError(Exception):
    def __init__(self, message, code="error"):
        super().__init__(message)
        self.code = code


# ---------- jobs ----------

def public_job(j):
    keys = ("id", "state", "progress", "stage", "error", "error_code", "created", "finished", "result", "position")
    return {k: j.get(k) for k in keys if j.get(k) is not None}


def save_job(j):
    path = os.path.join(JOBS, j["id"] + ".json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(public_job(j), f)
    os.replace(tmp, path)


def update(j, **kw):
    with jobs_lock:
        j.update(kw)
    if "progress" not in kw or kw.get("state"):
        save_job(j)


def load_jobs():
    for f in os.listdir(JOBS):
        if not f.endswith(".json"):
            continue
        try:
            with open(os.path.join(JOBS, f)) as fh:
                j = json.load(fh)
        except Exception:
            continue
        if j.get("state") in ("queued", "fetching", "signing"):
            j["state"] = "error"
            j["error"] = "The server restarted while signing. Try again."
            j["error_code"] = "restart"
            save_job(j)
        jobs[j["id"]] = j


# ---------- blobs ----------

def blob_path(sha):
    return os.path.join(BLOBS, sha)


def touch(path):
    try:
        os.utime(path, None)
    except OSError:
        pass


def free_disk():
    st = os.statvfs(DATA)
    return st.f_bavail * st.f_frsize


def dir_size(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


def cleanup():
    now = time.time()
    # Signed IPAs past their time.
    with jobs_lock:
        items = list(jobs.values())
    for j in items:
        r = j.get("result") or {}
        if r.get("expires") and r["expires"] < now:
            shutil.rmtree(os.path.join(OUT, r.get("token", "-")), ignore_errors=True)
            j["result"] = None
            j["state"] = "expired"
            save_job(j)
        if (j.get("finished") or j.get("created", now)) < now - 7 * 24 * 3600:
            with jobs_lock:
                jobs.pop(j["id"], None)
            try:
                os.remove(os.path.join(JOBS, j["id"] + ".json"))
            except OSError:
                pass
    # Output folders nobody knows about any more.
    known = {(j.get("result") or {}).get("token") for j in items}
    for d in os.listdir(OUT):
        p = os.path.join(OUT, d)
        if d not in known and os.path.getmtime(p) < now - 3600:
            shutil.rmtree(p, ignore_errors=True)
    # Outputs over the cap, oldest first.
    outs = sorted((os.path.getmtime(os.path.join(OUT, d)), d) for d in os.listdir(OUT))
    total = sum(dir_size(os.path.join(OUT, d)) for _, d in outs)
    for _, d in outs:
        if total <= OUT_CAP:
            break
        p = os.path.join(OUT, d)
        total -= dir_size(p)
        shutil.rmtree(p, ignore_errors=True)
    # Blob cache.
    blobs = []
    for f in os.listdir(BLOBS):
        p = os.path.join(BLOBS, f)
        if f.endswith(".part"):
            if os.path.getmtime(p) < now - 12 * 3600:
                os.remove(p)
            continue
        blobs.append((os.path.getmtime(p), os.path.getsize(p), p))
    blobs.sort()
    total = sum(b[1] for b in blobs)
    for mtime, size, p in blobs:
        if mtime < now - BLOB_TTL or total > BLOB_CAP:
            try:
                os.remove(p)
                total -= size
            except OSError:
                pass
    # Stale temporary folders.
    for d in os.listdir(TMP):
        p = os.path.join(TMP, d)
        if os.path.getmtime(p) < now - 6 * 3600:
            shutil.rmtree(p, ignore_errors=True)


def cleaner():
    while True:
        try:
            cleanup()
        except Exception:
            log("cleanup failed", traceback.format_exc())
        time.sleep(600)


# ---------- fetching ----------

def fetch_url(url, dst, j, span):
    for prefix, local in LOCAL:
        if url.startswith(prefix):
            rel = urllib.parse.unquote(url[len(prefix):].split("?")[0])
            p = os.path.realpath(os.path.join(local, rel))
            if p.startswith(os.path.realpath(local) + os.sep) and os.path.isfile(p):
                shutil.copyfile(p, dst)
                return
    req = urllib.request.Request(url, headers={"User-Agent": "SayoSign/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r, open(dst, "wb") as f:
            total = int(r.headers.get("Content-Length") or 0)
            if total and total + MIN_FREE > free_disk():
                raise JobError("Not enough disk space on the server for this file", "disk")
            done = 0
            last = 0
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
                done += len(chunk)
                if done > MAX_UPLOAD:
                    raise JobError("The file is too large", "too_large")
                if total and time.time() - last > 0.5:
                    last = time.time()
                    update(j, progress=span[0] + span[1] * done / total)
    except JobError:
        raise
    except Exception as e:
        raise JobError(f"Cannot download {url}: {e}", "fetch")


def take_file(ref, dst, j, span, what):
    """ref is {"sha": ...} for an uploaded blob or {"url": ...} to fetch."""
    if ref.get("sha"):
        src = blob_path(ref["sha"])
        if not os.path.isfile(src):
            raise JobError(f"The server lost the uploaded {what}. Try again.", "missing_blob")
        touch(src)
        try:
            os.link(src, dst)
        except OSError:
            shutil.copyfile(src, dst)
    elif ref.get("url"):
        fetch_url(ref["url"], dst, j, span)
        if what == "IPA" and not zipfile.is_zipfile(dst):
            raise JobError(f"{ref['url']} is not an IPA", "fetch")
    else:
        raise JobError(f"No {what} given", "bad_request")


# ---------- signing ----------

def run_job(j, spec):
    jid = j["id"]
    tmp = os.path.join(TMP, jid)
    os.makedirs(tmp, mode=0o700)
    try:
        update(j, state="fetching", stage="fetch", progress=0.0)
        ipa = os.path.join(tmp, "in.ipa")
        take_file(spec["ipa"], ipa, j, (0.0, 0.25), "IPA")
        if os.path.getsize(ipa) * 3 + MIN_FREE > free_disk():
            raise JobError("Not enough disk space on the server", "disk")

        args = [BIN, "sign", "-P", "-i", ipa, "-o", os.path.join(tmp, "out.ipa")]
        ident = spec["identity"]
        if ident.get("key"):
            open(os.path.join(tmp, "key.der"), "wb").write(base64.b64decode(ident["key"]))
            open(os.path.join(tmp, "cert.der"), "wb").write(base64.b64decode(ident["cert"]))
            args += ["-K", os.path.join(tmp, "key.der"), "-X", os.path.join(tmp, "cert.der")]
        else:
            open(os.path.join(tmp, "cert.p12"), "wb").write(base64.b64decode(ident["p12"]))
            args += ["-k", os.path.join(tmp, "cert.p12"), "-p", ident.get("password", "")]
        open(os.path.join(tmp, "profile.mobileprovision"), "wb").write(base64.b64decode(spec["profile"]))
        args += ["-m", os.path.join(tmp, "profile.mobileprovision")]

        o = spec.get("options") or {}
        for key, flag in (("bundle_id", "-b"), ("name", "-n"), ("version", "-v"), ("short_version", "-s"), ("min_ios", "-M")):
            v = (o.get(key) or "").strip()
            if v:
                args += [flag, v]
        for key, flag in (("remove_plugins", "-x"), ("remove_watch", "-w"), ("remove_url_schemes", "-u"),
                          ("file_sharing", "-f"), ("container", "-C")):
            if o.get(key):
                args.append(flag)
        args += ["-z", str(max(0, min(9, int(o.get("compression", 1)))))]
        if spec.get("icon"):
            open(os.path.join(tmp, "icon.png"), "wb").write(base64.b64decode(spec["icon"]))
            args += ["-c", os.path.join(tmp, "icon.png")]
        if spec.get("entitlements"):
            open(os.path.join(tmp, "extra.entitlements"), "wb").write(base64.b64decode(spec["entitlements"]))
            args += ["-e", os.path.join(tmp, "extra.entitlements")]

        tweaks = spec.get("tweaks") or []
        for i, t in enumerate(tweaks):
            name = t.get("name", "")
            if not SAFE_NAME.match(name) or name in (".", ".."):
                raise JobError(f"Bad tweak name {name!r}", "bad_request")
            d = os.path.join(tmp, "tweaks", str(i))
            os.makedirs(d)
            dst = os.path.join(d, name)
            if name.lower().endswith(".framework"):
                z = dst + ".zip"
                take_file(t, z, j, (0.25, 0.0), name)
                with zipfile.ZipFile(z) as zf:
                    zf.extractall(d)
                os.remove(z)
                if not os.path.isdir(dst):
                    raise JobError(f"{name}: the archive has no {name} folder", "bad_request")
            else:
                take_file(t, dst, j, (0.25, 0.0), name)
            args += ["-l", dst]
        if tweaks:
            hook = spec.get("hook")
            if hook and hook.get("sha"):
                d = os.path.join(tmp, "hook")
                os.makedirs(d)
                z = os.path.join(d, "hook.zip")
                take_file(hook, z, j, (0.25, 0.0), "hook framework")
                with zipfile.ZipFile(z) as zf:
                    zf.extractall(d)
                fw = os.path.join(d, "CydiaSubstrate.framework")
                if os.path.isdir(fw):
                    args += ["-H", fw]
        for name in spec.get("remove_embedded") or []:
            if SAFE_NAME.match(name):
                args += ["-r", name]

        update(j, state="signing", stage="unzip", progress=0.25)
        env = dict(os.environ, TMPDIR=tmp)
        p = subprocess.Popen(["nice", "-n", "10"] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             env=env, text=True, bufsize=1)
        errors = []
        for line in p.stderr:
            line = line.strip()
            m = re.match(r"^progress ([0-9.]+) (\S*)", line)
            if m:
                update(j, progress=0.25 + 0.75 * float(m.group(1)), stage=m.group(2) or j.get("stage"))
            elif line:
                errors.append(line)
        p.wait()
        if p.returncode != 0:
            msg = next((e[7:] for e in reversed(errors) if e.startswith("error: ")), None) or (errors[0] if errors else "signing failed")
            raise JobError(msg, "sign")

        out = os.path.join(tmp, "out.ipa")
        info = {}
        with zipfile.ZipFile(out) as zf:
            for n in zf.namelist():
                if re.match(r"^Payload/[^/]+\.app/Info\.plist$", n):
                    info = plistlib.loads(zf.read(n))
                    break
        bid = info.get("CFBundleIdentifier", "")
        ver = info.get("CFBundleShortVersionString", "") or info.get("CFBundleVersion", "")
        name = info.get("CFBundleDisplayName") or info.get("CFBundleName") or spec.get("title") or "App"
        token = secrets.token_urlsafe(24)
        od = os.path.join(OUT, token)
        os.makedirs(od)
        fname = re.sub(r"[^A-Za-z0-9._-]+", "_", f"{name}_{ver}") or "app"
        fname = fname[:80] + ".ipa"
        shutil.move(out, os.path.join(od, fname))
        ipa_url = f"{PUBLIC}/{token}/{urllib.parse.quote(fname)}"
        manifest = {"items": [{"assets": [{"kind": "software-package", "url": ipa_url}],
                               "metadata": {"bundle-identifier": bid, "bundle-version": ver or "1.0",
                                            "kind": "software", "title": name}}]}
        with open(os.path.join(od, "manifest.plist"), "wb") as f:
            plistlib.dump(manifest, f)
        os.chmod(od, 0o755)
        manifest_url = f"{PUBLIC}/{token}/manifest.plist"
        result = {"token": token, "ipa_url": ipa_url, "manifest_url": manifest_url,
                  "itms_url": "itms-services://?action=download-manifest&url=" + urllib.parse.quote(manifest_url, safe=""),
                  "size": os.path.getsize(os.path.join(od, fname)), "bundle_id": bid, "version": ver,
                  "name": name, "expires": int(time.time() + OUT_TTL)}
        update(j, state="done", progress=1.0, stage="done", result=result, finished=int(time.time()))
        log("job", jid, "done", bid, ver, result["size"])
    except JobError as e:
        update(j, state="error", error=str(e), error_code=e.code, finished=int(time.time()))
        log("job", jid, "failed", e.code, e)
    except Exception as e:
        update(j, state="error", error=f"Server error: {e}", error_code="server", finished=int(time.time()))
        log("job", jid, "crashed", traceback.format_exc())
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def worker():
    while True:
        j, spec = work.get()
        try:
            run_job(j, spec)
        finally:
            spec.clear()
            work.task_done()


def validate(spec):
    if not isinstance(spec, dict):
        raise JobError("The job must be a JSON object", "bad_request")
    ident = spec.get("identity") or {}
    if not ((ident.get("key") and ident.get("cert")) or ident.get("p12")):
        raise JobError("No certificate given", "bad_request")
    if not spec.get("profile"):
        raise JobError("No provisioning profile given", "bad_request")
    refs = [spec.get("ipa") or {}] + list(spec.get("tweaks") or [])
    if (spec.get("tweaks") and spec.get("hook")):
        refs.append(spec["hook"])
    need = []
    for r in refs:
        sha = r.get("sha")
        if sha:
            if not SHA_RE.match(sha):
                raise JobError("Bad blob id", "bad_request")
            if not os.path.isfile(blob_path(sha)):
                need.append(sha)
        elif not r.get("url"):
            raise JobError("Every file needs a sha or a url", "bad_request")
        elif not r["url"].lower().startswith(("https://", "http://")):
            raise JobError("Only http(s) URLs can be fetched", "bad_request")
    return need


# ---------- HTTP ----------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "SayoSignServer/" + VERSION

    def log_message(self, fmt, *a):
        pass

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (getattr(self, "extra", None) or {}).items():
            self.send_header(k, v)
        self.extra = None
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def authed(self):
        h = self.headers.get("Authorization", "")
        given = h[7:] if h.startswith("Bearer ") else ""
        if TOKEN and given and hmac.compare_digest(given.encode(), TOKEN.encode()):
            return True
        self.send_json(401, {"error": "Wrong or missing server key", "error_code": "auth"})
        return False

    def route(self):
        path = urllib.parse.urlparse(self.path).path
        path = re.sub(r"^/sign/api", "", path).rstrip("/")
        return path.split("/")[1:] if path else []

    def read_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 64 * 1024 * 1024:
            raise JobError("Request too large", "too_large")
        return json.loads(self.rfile.read(n) or b"null")

    def do_HEAD(self):
        parts = self.route()
        if not self.authed():
            return
        if len(parts) == 2 and parts[0] == "blobs" and SHA_RE.match(parts[1]):
            p = blob_path(parts[1])
            if os.path.isfile(p):
                touch(p)
                self.send_json(200, {})
            else:
                part = p + ".part"
                self.extra = {"X-Upload-Offset": str(os.path.getsize(part)) if os.path.isfile(part) else "0"}
                self.send_json(404, {})
            return
        self.send_json(404, {})

    def do_GET(self):
        parts = self.route()
        if not self.authed():
            return
        if parts == ["ping"]:
            with jobs_lock:
                queued = sum(1 for j in jobs.values() if j.get("state") in ("queued", "fetching", "signing"))
            self.send_json(200, {"ok": True, "server": "sayosign", "version": VERSION, "queue": queued,
                                 "free_disk": free_disk(), "ttl": OUT_TTL,
                                 "features": ["key", "p12", "url", "embedded", "container", "hook", "framework"]})
        elif len(parts) == 2 and parts[0] == "jobs":
            with jobs_lock:
                j = jobs.get(parts[1])
                pos = None
                if j and j.get("state") == "queued":
                    pos = sum(1 for x in jobs.values() if x.get("state") in ("queued", "fetching", "signing")
                              and x.get("created", 0) < j.get("created", 0))
                data = public_job(j) if j else None
            if data is None:
                self.send_json(404, {"error": "No such job", "error_code": "not_found"})
            else:
                if pos is not None:
                    data["position"] = pos
                self.send_json(200, data)
        else:
            self.send_json(404, {"error": "Not found"})

    def do_PUT(self):
        parts = self.route()
        if not self.authed():
            return
        if not (len(parts) == 2 and parts[0] == "blobs" and SHA_RE.match(parts[1])):
            self.send_json(404, {"error": "Not found"})
            return
        sha = parts[1]
        n = int(self.headers.get("Content-Length") or -1)
        if n < 0:
            self.send_json(411, {"error": "Content-Length required"})
            return
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        # Chunked: ?offset=<bytes already sent>&total=<file size>. Cloudflare caps a request
        # at 100 MB, so big files come in parts and an interrupted upload resumes at the offset.
        offset = int(q.get("offset", ["0"])[0])
        total = int(q.get("total", [str(n)])[0])
        if os.path.isfile(blob_path(sha)):
            self.close_connection = True
            self.send_json(201, {"sha": sha, "size": os.path.getsize(blob_path(sha)), "complete": True})
            return
        if total > MAX_UPLOAD or n > total:
            self.send_json(413, {"error": "The file is too large", "error_code": "too_large"})
            return
        part = blob_path(sha) + ".part"
        with upload_lock(sha):
            have = os.path.getsize(part) if os.path.isfile(part) else 0
            if offset == 0 and have:
                os.remove(part)
                have = 0
            if offset != have:
                self.close_connection = True
                self.send_json(409, {"error": "Wrong offset", "error_code": "offset", "offset": have})
                return
            if offset == 0 and total + MIN_FREE > free_disk():
                cleanup()
                if total + MIN_FREE > free_disk():
                    self.close_connection = True
                    self.send_json(507, {"error": "Not enough disk space on the server", "error_code": "disk"})
                    return
            left = n
            with open(part, "ab") as f:
                while left > 0:
                    chunk = self.rfile.read(min(left, 1 << 20))
                    if not chunk:
                        break
                    f.write(chunk)
                    left -= len(chunk)
            if left:
                self.close_connection = True
                self.send_json(400, {"error": "Upload interrupted", "offset": os.path.getsize(part)})
                return
            size = os.path.getsize(part)
            if size < total:
                self.send_json(200, {"sha": sha, "offset": size, "complete": False})
                return
            h = hashlib.sha256()
            with open(part, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            if h.hexdigest() != sha or size != total:
                os.remove(part)
                self.send_json(400, {"error": "Checksum mismatch", "error_code": "checksum"})
                return
            os.replace(part, blob_path(sha))
        self.send_json(201, {"sha": sha, "size": total, "complete": True})

    def do_POST(self):
        parts = self.route()
        if not self.authed():
            return
        if parts != ["jobs"]:
            self.send_json(404, {"error": "Not found"})
            return
        try:
            spec = self.read_json()
            need = validate(spec)
        except JobError as e:
            self.send_json(400, {"error": str(e), "error_code": e.code})
            return
        except ValueError:
            self.send_json(400, {"error": "Invalid JSON", "error_code": "bad_request"})
            return
        if need:
            self.send_json(409, {"error": "Upload these files first", "error_code": "need_blobs", "need": need})
            return
        jid = secrets.token_hex(8)
        j = {"id": jid, "state": "queued", "progress": 0.0, "stage": "queued", "created": int(time.time())}
        with jobs_lock:
            jobs[jid] = j
        save_job(j)
        work.put((j, spec))
        log("job", jid, "queued from", self.headers.get("X-Real-IP", self.client_address[0]))
        self.send_json(202, public_job(j))

    def do_DELETE(self):
        parts = self.route()
        if not self.authed():
            return
        if len(parts) == 2 and parts[0] == "jobs":
            with jobs_lock:
                j = jobs.get(parts[1])
            if not j:
                self.send_json(404, {"error": "No such job"})
                return
            r = j.get("result") or {}
            if r.get("token"):
                shutil.rmtree(os.path.join(OUT, r["token"]), ignore_errors=True)
            update(j, result=None, state="deleted" if j.get("state") == "done" else j.get("state"))
            self.send_json(200, {"ok": True})
        else:
            self.send_json(404, {"error": "Not found"})


def main():
    if not TOKEN or len(TOKEN) < 16:
        sys.exit("SAYOSIGN_TOKEN must be set (16+ characters)")
    if not PUBLIC:
        sys.exit("SAYOSIGN_PUBLIC must be set")
    if not os.access(BIN, os.X_OK):
        sys.exit(f"{BIN} is not executable")
    load_jobs()
    threading.Thread(target=worker, daemon=True).start()
    threading.Thread(target=cleaner, daemon=True).start()
    host, port = LISTEN.rsplit(":", 1)
    srv = ThreadingHTTPServer((host, int(port)), Handler)
    srv.daemon_threads = True
    log(f"SayoSign server {VERSION} on {LISTEN}, public {PUBLIC}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
