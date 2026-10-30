#!/bin/sh
# anicli-web installer for casbox (Debian arm64 / Raspberry Pi)
#   search anime in a browser -> pick episodes -> files land in the Jellyfin TV library
# Run with:  sudo sh install.sh
set -eu

APP="/home/cas/anicli-web"
RUN_USER="${SUDO_USER:-cas}"
PORT="8181"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- sh "$0" "$@"
fi

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!!\033[0m %s\n' "$*" >&2; exit 1; }

say "checking packages"
need=""
for p in curl python3 sed grep; do command -v "$p" >/dev/null 2>&1 || need="$need $p"; done
command -v tput >/dev/null 2>&1 || need="$need ncurses-bin"
if [ -n "$need" ]; then
  apt-get update -qq
  apt-get install -y --no-install-recommends ca-certificates $need
fi

say "installing yt-dlp (latest, arch-independent build)"
if curl -fL --retry 2 -o /usr/local/bin/yt-dlp.tmp \
     https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp; then
  chmod 755 /usr/local/bin/yt-dlp.tmp
  mv /usr/local/bin/yt-dlp.tmp /usr/local/bin/yt-dlp
else
  [ -x /usr/local/bin/yt-dlp ] || die "could not download yt-dlp"
fi
/usr/local/bin/yt-dlp --version >/dev/null 2>&1 || die "yt-dlp is not runnable"

say "installing ani-cli"
curl -fsSL -o /usr/local/bin/ani-cli \
  https://raw.githubusercontent.com/pystardust/ani-cli/master/ani-cli
chmod 755 /usr/local/bin/ani-cli
grep -q '^version_number=' /usr/local/bin/ani-cli || die "ani-cli download looks wrong"

say "creating $APP"
mkdir -p "$APP"

cat > "$APP/server.py" <<'__SERVER_PY__'
#!/usr/bin/env python3
"""
anicli-web — a small self-hosted web front-end for ani-cli.

Pure Python 3 standard library. No pip installs.
  * search / episode list   -> drives ani-cli non-interactively via a menu shim
  * watch in browser        -> ani-cli "debug" player gives the HLS url + referer,
                               which we proxy so the browser can play it
  * download to library     -> ani-cli -d into a staging dir, then renamed+moved
                               into <library>/tv/<Show>/Season N/ for Jellyfin
"""
import base64
import json
import os
import re
import shutil
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, urljoin, unquote
from urllib.request import Request, urlopen

APP_DIR = os.path.dirname(os.path.abspath(__file__))
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")

DEFAULTS = {
    "port": 8181,
    "library_root": "/home/cas/Downloads",
    "staging_dir": "/home/cas/Downloads/ani-staging",
    "jellyfin_url": "http://127.0.0.1:8096",
    "jellyfin_key": "",
    "default_quality": "1080",
    "max_concurrent_downloads": 2,
}


def load_conf():
    conf = dict(DEFAULTS)
    path = os.path.join(APP_DIR, "config.json")
    if os.path.exists(path):
        try:
            conf.update(json.load(open(path)))
        except Exception as exc:
            print("[config] ignoring bad config.json: %s" % exc, flush=True)
    return conf


CONF = load_conf()
ANI = os.path.join(APP_DIR, "ani-cli")
SHIM = os.path.join(APP_DIR, "menushim")
JOBS = {}
JOBS_LOCK = threading.Lock()
DL_SEM = threading.Semaphore(int(CONF.get("max_concurrent_downloads", 2)))

PROGRESS_RE = re.compile(
    r"(\d+(?:\.\d+)?)%\s+of\s+~?\s*([\d.]+)([KMG]iB).*?at\s+([\d.]+)([KMG]iB/s)")
EPNUM_RE = re.compile(r"^(\d{1,4})(?:\.(\d{1,2}))?$")


# ---------------------------------------------------------------- helpers
def b64e(s):
    return base64.urlsafe_b64encode(s.encode()).decode().rstrip("=")


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)).decode()


def prox(url, ref):
    return "/px?u=%s&r=%s" % (b64e(url), b64e(ref or ""))


def clean_name(s, limit=110):
    s = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "", s or "")
    s = re.sub(r"\s+", " ", s).strip(" .")
    return s[:limit] or "Unknown"


def http_get_text(url, ref, timeout=20):
    req = Request(url, headers={"User-Agent": UA, "Referer": ref or "",
                                "Accept": "*/*"})
    with urlopen(req, timeout=timeout) as resp:
        return resp.read(), resp.headers.get("Content-Type", ""), resp.geturl()


# ---------------------------------------------------------------- ani-cli
def run_ani(args, pick=None, abort_on=None, download_dir=None, timeout=120,
            on_line=None):
    """Run the bundled ani-cli non-interactively. Returns (menus, stdout, log)."""
    tmp = os.path.join("/tmp", "anicli-%s" % uuid.uuid4().hex[:10])
    os.makedirs(tmp, exist_ok=True)
    logpath = os.path.join(tmp, "menu.log")
    env = os.environ.copy()
    env.update({
        "ANI_CLI_MENU": SHIM,
        "ANI_CLI_PLAYER": "debug",
        "ANI_CLI_BRANCH": "master",
        "SHIM_LOG": logpath,
        "PICK": str(pick) if pick is not None else "",
        "ABORT_ON": str(abort_on) if abort_on is not None else "",
        "TERM": "dumb",
    })
    if download_dir:
        env["ANI_CLI_DOWNLOAD_DIR"] = download_dir
    cmd = ["/bin/sh", ANI] + [str(a) for a in args]
    out, err = [], []
    try:
        proc = subprocess.Popen(cmd, cwd=tmp, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, errors="replace", bufsize=1)
        deadline = time.time() + timeout
        def pump(stream, sink):
            for line in stream:
                sink.append(line)
                if on_line:
                    on_line(line)
                if time.time() > deadline:
                    break
        t1 = threading.Thread(target=pump, args=(proc.stdout, out), daemon=True)
        t2 = threading.Thread(target=pump, args=(proc.stderr, err), daemon=True)
        t1.start(); t2.start()
        while proc.poll() is None and time.time() < deadline:
            time.sleep(0.2)
        if proc.poll() is None:
            proc.kill()
            err.append("\n[timeout]\n")
        t1.join(3); t2.join(3)
    except Exception as exc:  # pragma: no cover
        err.append("[launch error] %s\n" % exc)
    menus = {}
    try:
        raw = open(logpath, encoding="utf-8", errors="replace").read()
        for block in re.split(r"^=== MENU ", raw, flags=re.M)[1:]:
            head, _, body = block.partition("\n")
            num = head.split("|")[0].strip()
            menus[int(num)] = [l for l in body.splitlines() if l.strip()]
    except FileNotFoundError:
        pass
    shutil.rmtree(tmp, ignore_errors=True)
    return menus, "".join(out), "".join(err)


def search(q):
    menus, _, _ = run_ani(["-q", CONF["default_quality"], q], abort_on=1, timeout=45)
    res = []
    for line in menus.get(1, []):
        m = re.match(r"^(\d+)\s+(.+)$", line)
        if m:
            res.append({"n": int(m.group(1)), "title": m.group(2).strip()})
    return res


def episodes(q, pick):
    menus, _, _ = run_ani(["-q", CONF["default_quality"], q], pick=pick,
                          abort_on=2, timeout=60)
    eps = menus.get(2, [])
    return [e.strip() for e in eps if e.strip()]


def resolve_links(q, pick, ep, quality, dub):
    """Returns {'ref','urls':[{q,url}],'sub'} via ani-cli's debug player."""
    args = ["-q", quality or CONF["default_quality"], "-e", str(ep)]
    if dub:
        args.append("--dub")
    args.append(q)
    _, out, err = run_ani(args, pick=pick, timeout=90)
    ref = ""
    m = re.search(r"^REFERER:\[(.*?)\]", out, flags=re.M)
    if m:
        ref = m.group(1)
    urls = []
    for line in out.splitlines():
        m = re.match(r"^(\d{3,4})\s*>\s*(https?://\S+)$", line.strip())
        if m:
            urls.append({"q": m.group(1), "url": m.group(2)})
    sel = ""
    m = re.search(r"^Selected link:\s*\n\s*(https?://\S+)", out, flags=re.M)
    if m:
        sel = m.group(1)
    sub = ""
    m = re.search(r"^Subtitles:\s*\n\s*(https?://\S+)", out, flags=re.M)
    if m:
        sub = m.group(1)
    if not sel and urls:
        sel = urls[0]["url"]
    return {"ref": ref, "selected": sel, "urls": urls, "sub": sub,
            "log": (out + err)[-1200:]}


# ---------------------------------------------------------------- library
def anilist_year(title):
    payload = json.dumps({
        "query": "query($s:String){Media(search:$s,type:ANIME){seasonYear startDate{year}}}",
        "variables": {"s": title}}).encode()
    req = Request("https://graphql.anilist.co", data=payload,
                  headers={"Content-Type": "application/json", "Accept": "application/json",
                           "Accept-Encoding": "identity", "User-Agent": UA})
    try:
        with urlopen(req, timeout=8) as r:
            raw = r.read()
        if raw[:2] == b"\x1f\x8b":
            import gzip
            raw = gzip.decompress(raw)
        data = json.loads(raw.decode("utf-8", "replace"))
        media = (data.get("data") or {}).get("Media") or {}
        return media.get("seasonYear") or (media.get("startDate") or {}).get("year")
    except Exception as exc:
        print("[anilist] %s" % exc, flush=True)
        return None


def jellyfin_refresh():
    if not CONF.get("jellyfin_key"):
        return
    url = "%s/Library/Refresh?api_key=%s" % (CONF["jellyfin_url"].rstrip("/"),
                                             CONF["jellyfin_key"])
    try:
        urlopen(Request(url, data=b"", method="POST"), timeout=8).read()
    except Exception:
        pass


def ep_tag(season, ep):
    m = EPNUM_RE.match(str(ep))
    ss = int(season or 1)
    if m:
        num = int(m.group(1))
        frac = m.group(2)
        tag = "S%02dE%02d" % (ss, num)
        if frac:
            tag += "-%s" % frac
        return tag
    return "S%02dE%s" % (ss, re.sub(r"[^0-9A-Za-z.-]", "", str(ep)) or "00")


def finalise(job, staging):
    root = CONF["library_root"]
    files = []
    for dirpath, _, names in os.walk(staging):
        for n in names:
            files.append(os.path.join(dirpath, n))
    vids = [f for f in files if f.lower().endswith((".mp4", ".mkv", ".webm"))]
    subs = [f for f in files if f.lower().endswith((".vtt", ".srt", ".ass"))]
    if not vids:
        raise RuntimeError("ani-cli finished but produced no video file")
    vid = max(vids, key=os.path.getsize)
    title = clean_name(job["title"])
    year = anilist_year(job["title"])
    tag = ep_tag(job.get("season") or 1, job["ep"])
    show_dir = "%s (%s)" % (title, year) if year else title
    if job.get("target") == "movie":
        folder = os.path.join(root, "movies", show_dir)
        base = "%s (%s)" % (title, year) if year else title
    else:
        folder = os.path.join(root, "tv", show_dir, "Season %d" % int(job.get("season") or 1))
        base = "%s - %s" % (title, tag)
    os.makedirs(folder, exist_ok=True)
    ext = os.path.splitext(vid)[1].lower()
    dest = os.path.join(folder, base + ext)
    n = 2
    while os.path.exists(dest):
        dest = os.path.join(folder, "%s (%d)%s" % (base, n, ext))
        n += 1
    shutil.move(vid, dest)
    if subs:
        sub_dest = os.path.join(folder, os.path.splitext(os.path.basename(dest))[0] + ".en.vtt")
        try:
            shutil.move(max(subs, key=os.path.getsize), sub_dest)
        except Exception:
            pass
    shutil.rmtree(staging, ignore_errors=True)
    jellyfin_refresh()
    return dest


def set_job(jid, **kw):
    with JOBS_LOCK:
        if jid in JOBS:
            JOBS[jid].update(kw)


def run_download(jid, job):
    with DL_SEM:
        staging = os.path.join(CONF["staging_dir"], jid)
        os.makedirs(staging, exist_ok=True)
        set_job(jid, status="running", progress=0.0, message="resolving links…")
        args = ["-q", job.get("quality") or CONF["default_quality"], "-d",
                "-e", str(job["ep"])]
        if job.get("dub"):
            args.append("--dub")
        args.append(job["query"])
        state = {"pct": 0.0}

        def on_line(line):
            m = PROGRESS_RE.search(line)
            if m:
                state["pct"] = float(m.group(1))
                set_job(jid, progress=min(0.99, state["pct"] / 100.0),
                        message="downloading %s%% at %s%s" % (m.group(1), m.group(4), m.group(5)))
        menus, out, err = run_ani(args, pick=job["pick"], download_dir=staging,
                                  timeout=3600, on_line=on_line)
        vids = []
        for dirpath, _, names in os.walk(staging):
            vids += [n for n in names if n.lower().endswith((".mp4", ".mkv"))]
        if not vids:
            set_job(jid, status="error", progress=0.0,
                    message="download failed", log=(out + err)[-1500:])
            return
        set_job(jid, progress=0.97, message="filing into Jellyfin library…")
        try:
            dest = finalise(job, staging)
            set_job(jid, status="done", progress=1.0, message="saved",
                    path=dest.replace(CONF["library_root"], "/data/downloads"),
                    finished=time.time())
        except Exception as exc:
            set_job(jid, status="error", message="could not file file: %s" % exc,
                    log=(out + err)[-1500:])


def start_job(data):
    jid = uuid.uuid4().hex[:8]
    job = {
        "id": jid, "query": data["q"], "pick": int(data.get("pick") or 1),
        "title": data.get("title") or data["q"], "ep": str(data.get("ep") or "1"),
        "season": int(data.get("season") or 1), "quality": data.get("quality"),
        "dub": bool(data.get("dub")), "target": data.get("target") or "tv",
        "status": "queued", "progress": 0.0, "message": "queued",
        "created": time.time(), "path": "", "log": "",
    }
    with JOBS_LOCK:
        JOBS[jid] = job
    threading.Thread(target=run_download, args=(jid, job), daemon=True).start()
    return job


# ---------------------------------------------------------------- HTTP
PAGES = {"/": "index.html", "/index.html": "index.html"}


class Handler(BaseHTTPRequestHandler):
    server_version = "anicli-web/1.0"

    def log_message(self, fmt, *args):
        print("[http] " + fmt % args, flush=True)

    # ---- plumbing
    def send_body(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def json(self, obj, code=200):
        self.send_body(code, json.dumps(obj))

    def do_GET(self):
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        try:
            if u.path in PAGES:
                return self.static(PAGES[u.path])
            if u.path == "/hls.min.js":
                return self.static("hls.min.js")
            if u.path == "/api/search":
                return self.json({"results": search(qs.get("q", [""])[0])})
            if u.path == "/api/episodes":
                return self.json({"episodes": episodes(qs.get("q", [""])[0],
                                                       int(qs.get("pick", ["1"])[0]))})
            if u.path == "/api/watch":
                return self.json(resolve_links(
                    qs.get("q", [""])[0], int(qs.get("pick", ["1"])[0]),
                    qs.get("ep", ["1"])[0], qs.get("quality", [None])[0],
                    qs.get("dub", ["0"])[0] in ("1", "true")))
            if u.path == "/px":
                return self.proxy(qs)
            if u.path == "/api/jobs":
                with JOBS_LOCK:
                    jobs = sorted(JOBS.values(), key=lambda j: j["created"], reverse=True)
                return self.json({"jobs": jobs[:40]})
            if u.path == "/api/status":
                return self.json({
                    "ok": True, "port": CONF["port"],
                    "ani_cli": os.path.exists(ANI), "shim": os.path.exists(SHIM),
                    "library_root": CONF["library_root"],
                    "staging_dir": CONF["staging_dir"],
                    "ytdlp": shutil.which("yt-dlp") is not None,
                    "dmenu_conflict": shutil.which("dmenu") is not None,
                })
            return self.json({"error": "not found"}, 404)
        except Exception as exc:
            print("[error] %s: %s" % (u.path, exc), flush=True)
            return self.json({"error": str(exc)}, 500)

    def do_POST(self):
        u = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            data = json.loads(raw.decode() or "{}")
        except Exception:
            return self.json({"error": "bad json"}, 400)
        try:
            if u.path == "/api/download":
                return self.json({"job": start_job(data)})
            if u.path == "/api/job-clear":
                with JOBS_LOCK:
                    for jid in list(JOBS):
                        if JOBS[jid]["status"] in ("done", "error"):
                            JOBS.pop(jid, None)
                return self.json({"ok": True})
            return self.json({"error": "not found"}, 404)
        except Exception as exc:
            print("[error] POST %s: %s" % (u.path, exc), flush=True)
            return self.json({"error": str(exc)}, 500)

    # ---- static
    def static(self, name):
        path = os.path.join(APP_DIR, name)
        if not os.path.exists(path):
            if name == "hls.min.js":
                return self.send_body(404, "/* hls.js not installed */", "text/javascript")
            return self.send_body(404, "not found", "text/plain")
        ctype = {"index.html": "text/html; charset=utf-8",
                 "hls.min.js": "text/javascript; charset=utf-8"}.get(name, "text/plain")
        with open(path, "rb") as fh:
            self.send_body(200, fh.read(), ctype)

    # ---- stream proxy
    def proxy(self, qs):
        try:
            url = b64d(qs.get("u", [""])[0])
            ref = b64d(qs.get("r", [""])[0])
        except Exception:
            return self.send_body(400, "bad request", "text/plain")
        if not url.startswith("http"):
            return self.send_body(400, "bad url", "text/plain")
        try:
            body, ctype, final = http_get_text(url, ref, timeout=30)
        except Exception as exc:
            print("[proxy] %s -> %s" % (url[:90], exc), flush=True)
            return self.send_body(502, "upstream error: %s" % exc, "text/plain")
        is_playlist = (b"#EXTM3U" in body[:2000]) or ("mpegurl" in ctype.lower())
        if is_playlist:
            text = body.decode("utf-8", "replace")
            out = []
            for raw in text.splitlines():
                line = raw.strip()
                if not line:
                    out.append(raw)
                    continue
                if line.startswith("#"):
                    if 'URI="' in line:
                        line = re.sub(r'URI="([^"]+)"',
                                      lambda m: 'URI="%s"' % prox(urljoin(final, m.group(1)), ref),
                                      line)
                    out.append(line)
                else:
                    out.append(prox(urljoin(final, line), ref))
            return self.send_body(200, "\n".join(out) + "\n",
                                  "application/vnd.apple.mpegurl")
        ext = os.path.splitext(urlparse(final).path)[1].lower()
        ctype = {".ts": "video/mp2t", ".m4s": "video/iso.segment", ".mp4": "video/mp4",
                 ".key": "application/octet-stream", ".vtt": "text/vtt; charset=utf-8",
                 ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
                 ".aac": "audio/aac", ".m4a": "audio/mp4"}.get(ext, ctype or "application/octet-stream")
        return self.send_body(200, body, ctype)


def main():
    if not os.path.exists(ANI):
        print("FATAL: %s missing" % ANI)
    if shutil.which("dmenu"):
        print("[warn] dmenu is installed — ani-cli prefers it over the shim when "
              "stdin is not a tty. Remove dmenu if search fails.", flush=True)
    os.makedirs(CONF["staging_dir"], exist_ok=True)
    port = int(CONF["port"])
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print("anicli-web listening on http://0.0.0.0:%d" % port, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()

__SERVER_PY__

cat > "$APP/index.html" <<'__INDEX_HTML__'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#0f1116">
<title>AniCLI</title>
<style>
  :root{--bg:#0f1116;--card:#181b23;--card2:#1f2430;--line:#2a3040;--fg:#e8ecf4;--dim:#8b93a5;--acc:#7c5cff;--ok:#3ddc97;--err:#ff5f6d}
  *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
  body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;padding:16px 14px 60px;max-width:820px;margin:0 auto}
  h1{font-size:19px;margin:0 0 2px;letter-spacing:.3px}
  h1 span{color:var(--acc)}
  .sub{color:var(--dim);font-size:12.5px;margin-bottom:16px}
  .row{display:flex;gap:8px;align-items:center}
  input,select,button{font:inherit;color:var(--fg)}
  input[type=text],input[type=number],select{background:var(--card2);border:1px solid var(--line);border-radius:11px;padding:11px 12px;width:100%;outline:none}
  input:focus,select:focus{border-color:var(--acc)}
  button{background:var(--card2);border:1px solid var(--line);border-radius:11px;padding:11px 15px;cursor:pointer;font-weight:600}
  button:active{transform:scale(.98)}
  button.primary{background:var(--acc);border-color:var(--acc);color:#fff}
  button.ghost{background:transparent}
  .card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px;margin-top:14px}
  .hide{display:none!important}
  .res{padding:11px 12px;border-radius:11px;cursor:pointer;display:flex;gap:10px;align-items:center}
  .res:hover,.res:active{background:var(--card2)}
  .res .n{color:var(--dim);font-size:12px;min-width:18px;font-variant-numeric:tabular-nums}
  .res.sel{background:rgba(124,92,255,.16);border:1px solid rgba(124,92,255,.5)}
  .eps{display:grid;grid-template-columns:repeat(auto-fill,minmax(64px,1fr));gap:7px;margin-top:10px;max-height:280px;overflow:auto}
  .ep{background:var(--card2);border:1px solid var(--line);border-radius:9px;padding:9px 4px;text-align:center;font-size:13px;font-variant-numeric:tabular-nums;cursor:pointer}
  .ep:active{background:var(--acc);border-color:var(--acc)}
  .ep.busy{opacity:.5;pointer-events:none}
  label.f{display:block;font-size:11.5px;color:var(--dim);margin:0 0 5px;text-transform:uppercase;letter-spacing:.6px}
  .grid2{display:grid;grid-template-columns:1fr 1fr;gap:10px}
  .grid3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px}
  .job{background:var(--card2);border:1px solid var(--line);border-radius:12px;padding:11px 12px;margin-top:9px;font-size:13.5px}
  .job .jtop{display:flex;justify-content:space-between;gap:8px;align-items:baseline}
  .job .jtitle{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .job .jp{color:var(--dim);font-size:11.5px;margin-top:3px}
  .bar{height:5px;background:#0c0e13;border-radius:99px;overflow:hidden;margin-top:8px}
  .bar i{display:block;height:100%;background:var(--acc);border-radius:99px;transition:width .4s}
  .job.done .bar i{background:var(--ok)}
  .job.error .bar i{background:var(--err)}
  .tag{font-size:10.5px;padding:2px 7px;border-radius:99px;background:#262c3a;color:var(--dim);text-transform:uppercase;letter-spacing:.5px}
  .tag.done{background:rgba(61,220,151,.15);color:var(--ok)}
  .tag.error{background:rgba(255,95,109,.15);color:var(--err)}
  .tag.running{background:rgba(124,92,255,.18);color:#b3a2ff}
  .muted{color:var(--dim);font-size:13px}
  .toast{position:fixed;left:14px;right:14px;bottom:18px;background:#2a1b22;border:1px solid #5c2b34;color:#ffd9de;padding:12px 14px;border-radius:12px;font-size:13.5px;z-index:50}
  .spin{display:inline-block;width:13px;height:13px;border:2px solid var(--line);border-top-color:var(--acc);border-radius:50%;animation:s .8s linear infinite;vertical-align:-2px}
  @keyframes s{to{transform:rotate(360deg)}}
  .hint{color:var(--dim);font-size:11.5px;margin-top:6px}
</style>
</head>
<body>
<h1>Ani<span>CLI</span> <span style="color:var(--dim);font-weight:400;font-size:12px">→ Jellyfin</span></h1>
<div class="sub">Search, pick an episode, it lands in your TV library</div>

<div class="card">
  <div class="row">
    <input id="q" type="text" placeholder="Search anime…" autocomplete="off">
    <button class="primary" id="go" style="min-width:74px">Go</button>
  </div>
  <div class="hint">Tip: use the Japanese title if the English one gives nothing.</div>
  <div id="results" style="margin-top:10px"></div>
</div>

<div class="card hide" id="showcard">
  <div class="row" style="justify-content:space-between">
    <div style="font-weight:700;font-size:15.5px" id="showtitle">—</div>
    <button class="ghost" onclick="resetShow()" style="padding:6px 10px;font-size:12px">clear</button>
  </div>
  <div class="grid3" style="margin-top:12px">
    <div><label class="f">Quality</label>
      <select id="quality"><option>1080</option><option>720</option><option>360</option></select></div>
    <div><label class="f">Season #</label>
      <input id="season" type="number" min="0" max="30" value="1"></div>
    <div><label class="f">Save as</label>
      <select id="target"><option value="tv">TV</option><option value="movie">Movie</option></select></div>
  </div>
  <div class="row" style="margin-top:10px">
    <label style="display:flex;gap:8px;align-items:center;font-size:13.5px;color:var(--dim)">
      <input id="dub" type="checkbox" style="width:18px;height:18px;accent-color:var(--acc)"> English dub
    </label>
  </div>
  <div id="epload" class="muted" style="margin-top:12px">loading episodes…</div>
  <div class="eps hide" id="eps"></div>
  <div class="row" style="margin-top:12px">
    <input id="range" type="text" placeholder="Range e.g. 1-12" style="flex:1">
    <button id="dlrange">Download</button>
  </div>
  <div class="hint">Tap an episode to download it, or type a range. One job per episode, two at a time.</div>
</div>

<div class="card">
  <div class="row" style="justify-content:space-between">
    <div style="font-weight:700">Queue</div>
    <button class="ghost" id="clearjobs" style="padding:5px 10px;font-size:12px">clear finished</button>
  </div>
  <div id="jobs"><div class="muted" style="margin-top:6px">Nothing yet.</div></div>
</div>

<script>
const $ = s => document.querySelector(s);
let STATE = {q:"", pick:null, title:"", eps:[]};

function toast(msg){
  const t=document.createElement('div'); t.className='toast'; t.textContent=msg;
  document.body.appendChild(t); setTimeout(()=>t.remove(), 5000);
}
async function api(path, opts){
  const r = await fetch(path, opts);
  let j = null; try{ j = await r.json(); }catch(e){}
  if(!r.ok) throw new Error((j&&j.error)||('HTTP '+r.status));
  return j;
}
function esc(s){ return s.replace(/[&<>"]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }

$('#go').onclick = doSearch;
$('#q').addEventListener('keydown', e=>{ if(e.key==='Enter') doSearch(); });

async function doSearch(){
  const q = $('#q').value.trim(); if(!q) return;
  $('#go').innerHTML = '<span class="spin"></span>';
  $('#results').innerHTML = '';
  try{
    const {results} = await api('/api/search?q='+encodeURIComponent(q));
    if(!results.length) return toast('No results. Try the Japanese title.');
    STATE.q = q;
    $('#results').innerHTML = results.map(r =>
      `<div class="res" data-n="${r.n}" data-t="${esc(r.title)}"><span class="n">${r.n}</span><span>${esc(r.title)}</span></div>`
    ).join('');
    document.querySelectorAll('.res').forEach(el => el.onclick = () => pickShow(el, q));
  }catch(e){ toast('Search failed: '+e.message); }
  finally{ $('#go').textContent='Go'; }
}

async function pickShow(el, q){
  document.querySelectorAll('.res').forEach(x=>x.classList.remove('sel'));
  el.classList.add('sel');
  STATE.pick = +el.dataset.n; STATE.title = el.dataset.t;
  $('#showtitle').textContent = STATE.title;
  $('#showcard').classList.remove('hide');
  $('#epload').classList.remove('hide');
  $('#epload').innerHTML = '<span class="spin"></span> loading episodes…';
  $('#eps').classList.add('hide'); $('#eps').innerHTML='';
  try{
    const {episodes} = await api(`/api/episodes?q=${encodeURIComponent(q)}&pick=${STATE.pick}`);
    STATE.eps = episodes;
    if(!episodes.length){ $('#epload').textContent='No episodes found.'; return; }
    $('#epload').classList.add('hide');
    $('#eps').classList.remove('hide');
    $('#eps').innerHTML = episodes.map(e=>`<div class="ep" data-e="${esc(e)}">${esc(e)}</div>`).join('');
    $('#eps').querySelectorAll('.ep').forEach(b => b.onclick = ()=> queue(+b.dataset.e));
  }catch(e){ $('#epload').textContent = 'Failed: '+e.message; }
}

function resetShow(){
  $('#showcard').classList.add('hide'); $('#eps').innerHTML='';
  document.querySelectorAll('.res').forEach(x=>x.classList.remove('sel'));
  STATE.pick=null;
}

async function queue(ep){
  const body = {q:STATE.q, pick:STATE.pick, title:STATE.title, ep:String(ep),
    season:+$('#season').value||1, quality:$('#quality').value,
    dub:$('#dub').checked, target:$('#target').value};
  try{ await api('/api/download',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
       toast(`Queued ${STATE.title} — ep ${ep}`); poll(); }
  catch(e){ toast('Queue failed: '+e.message); }
}

$('#dlrange').onclick = ()=>{
  const raw = $('#range').value.trim();
  if(!raw) return toast('Type a range, e.g. 1-12');
  let list = [];
  if(raw.includes('-')){
    const [a,b] = raw.split('-').map(x=>parseInt(x,10));
    if(!(a<=b)) return toast('Bad range');
    if(b-a > 60) return toast('Max 60 episodes at once');
    for(let i=a;i<=b;i++) list.push(i);
  } else {
    list = raw.split(/[ ,]+/).filter(Boolean);
  }
  if(!STATE.pick) return toast('Pick a show first');
  list.forEach((ep,i)=> setTimeout(()=>queue(ep), i*150));
};

$('#clearjobs').onclick = async ()=>{ try{ await api('/api/job-clear',{method:'POST'}); poll(); }catch(e){} };

function jobHTML(j){
  const pct = Math.round((j.progress||0)*100);
  const label = j.status==='done' ? 'done' : j.status;
  return `<div class="job ${j.status}">
    <div class="jtop"><div class="jtitle">${esc(j.title)} — ep ${esc(j.ep)}</div>
      <span class="tag ${j.status}">${label}</span></div>
    <div class="jp">${esc(j.message||'')}</div>
    <div class="bar"><i style="width:${j.status==='done'?'100':pct}%"></i></div>
  </div>`;
}

let pollTimer = null;
async function poll(){
  try{
    const {jobs} = await api('/api/jobs');
    if(!jobs.length){ $('#jobs').innerHTML = '<div class="muted" style="margin-top:6px">Nothing yet.</div>'; }
    else $('#jobs').innerHTML = jobs.map(jobHTML).join('');
    const active = jobs.some(j=>['queued','running'].includes(j.status));
    if(active){ clearTimeout(pollTimer); pollTimer = setTimeout(poll, 2500); }
  }catch(e){}
}
poll();
</script>
</body>
</html>

__INDEX_HTML__

cat > "$APP/menushim" <<'__MENUSHIM__'
#!/bin/sh
# Menu shim for ani-cli: makes it non-interactive and logs each menu it is shown.
# Called by ani-cli as:  menushim "<prompt>" [flags]
LOG="${SHIM_LOG:-/tmp/anicli-menu.log}"
CNT="${LOG}.count"
N=$(cat "$CNT" 2>/dev/null || echo 0)
N=$((N + 1))
echo "$N" > "$CNT"
inp=$(cat)
{
  printf '=== MENU %s | %s\n' "$N" "$1"
  printf '%s\n' "$inp"
} >> "$LOG"
if [ -n "$ABORT_ON" ] && [ "$ABORT_ON" = "$N" ]; then
  exit 1
fi
sel="${PICK:-1}"
printf '%s\n' "$inp" | sed -n "${sel}p"

__MENUSHIM__
chmod 755 "$APP/menushim"

# ani-cli's debug player does not print the stream Referer, which we need for
# in-browser playback later. Patch a local copy; downloads use it too, harmlessly.
cp /usr/local/bin/ani-cli "$APP/ani-cli"
sed -i 's|debug) printf "All links:|debug) printf "REFERER:[%s]\\n" "$refr"; printf "All links:|' "$APP/ani-cli" || true
chmod 755 "$APP/ani-cli"

if [ ! -f "$APP/config.json" ]; then
cat > "$APP/config.json" <<'__CONF__'
{
  "port": 8181,
  "library_root": "/home/cas/Downloads",
  "staging_dir": "/home/cas/Downloads/ani-staging",
  "jellyfin_url": "http://127.0.0.1:8096",
  "jellyfin_key": "",
  "default_quality": "1080",
  "max_concurrent_downloads": 2
}
__CONF__
fi

mkdir -p /home/cas/Downloads/ani-staging
chown -R "$RUN_USER":"$RUN_USER" "$APP" /home/cas/Downloads/ani-staging

say "installing systemd service"
cat > /etc/systemd/system/anicli-web.service <<__UNIT__
[Unit]
Description=anicli-web (ani-cli web UI -> Jellyfin)
After=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$APP
ExecStart=/usr/bin/python3 $APP/server.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
__UNIT__

systemctl daemon-reload
systemctl enable --now anicli-web.service
sleep 3
systemctl is-active --quiet anicli-web.service || {
  journalctl -u anicli-web -n 25 --no-pager || true
  die "service failed to start"
}

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
say "done"
printf '\n  Open:  http://%s:%s\n\n' "${IP:-<pi-ip>}" "$PORT"
printf '  Logs:  journalctl -u anicli-web -f\n'
printf '  Edit:  %s/config.json  (then: sudo systemctl restart anicli-web)\n' "$APP"
printf '  Update ani-cli later:  sudo curl -fsSL -o /usr/local/bin/ani-cli https://raw.githubusercontent.com/pystardust/ani-cli/master/ani-cli && sudo systemctl restart anicli-web\n\n'
