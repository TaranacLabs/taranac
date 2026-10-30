#!/usr/bin/env python3
# =============================================================================
# image-verify.py — are the files a container of IMAGE would see the image's files?
#
# WHY THIS EXISTS AT ALL
# ----------------------
# The 1.3.3 OVA shipped two preloaded images whose unpacked files were cut short:
# /usr/local/bin/etcd in quay.io/coreos/etcd:v3.5.17 was 0 bytes and docker:27.5.1-cli
# stopped at exactly 20 MiB. The golden VM had been hard-reset after the preload, and
# ext4 keeps the names of freshly written files but not always their contents. The
# image's digest lives in metadata, so `docker image inspect` and the IMAGES.lock check
# both said "the release's image" — while `add-witness` died on `exec format error`
# and the update finisher segfaulted. A digest check cannot see this; only reading
# the files can.
#
# HOW
# ---
# expected = the image's layers as `docker save` streams them (each blob is hashed
#            against its name, whiteouts applied in order), file by file.
# actual   = `docker export` of a created, never started container: the unpacked
#            snapshot exactly as a container's root filesystem.
# Every regular file must be present with the same SHA-256. Both sides are streamed:
# nothing is written to disk.
#
# REPAIR (--repair)
# -----------------
# A replacement in hand BEFORE anything is removed. The damage is in the unpacked
# files; the image's own layers (the blobs `docker save` streams, hashed by the check)
# are intact — so the first source is a copy of them in a file, which needs no network
# and cures an air-gapped appliance. Only when that copy cannot be made (no room, or
# the blobs are damaged too) is the registry asked, and it must answer for the image
# NOW; with neither, the image is left as it is and the operator gets the cure.
# Then the image is removed — its stopped containers first: `docker rmi` while any
# container, even a stopped one, references it leaves the damaged snapshot in place
# and the reload reuses it (seen on the lab, 28.10.2026) — and brought back, and read
# again. A RUNNING container on a damaged image is never stopped from here: the
# operator is told which one and why. All damaged images are removed before any comes
# back, so two images sharing a damaged layer do not hand it to each other.
#
# CONTRACT WITH THE CALLER (bash)
# -------------------------------
#   image-verify.py [--repair] [--tmp DIR] [--jobs N] IMAGE...
#   exit 0  every image is intact (after the repair, with --repair)
#   exit 1  at least one image is broken; each is named with its cure on stderr
#   exit 2  docker could not be asked (not an image verdict)
# stdout: one `ok <image>` / `BROKEN <image>` line per image.
# =============================================================================
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import uuid
from concurrent.futures import ThreadPoolExecutor

# A created container gets these as mount points of its own; they are not the image's.
OWN_MOUNTS = {".dockerenv", "etc/hosts", "etc/hostname", "etc/resolv.conf"}
CHUNK = 1 << 20


class DockerError(Exception):
    pass


class HashingReader:
    """A file object that hashes every byte read through it."""

    def __init__(self, raw):
        self.raw, self.h = raw, hashlib.sha256()

    def read(self, n=-1):
        data = self.raw.read(n)
        self.h.update(data)
        return data

    def drain(self):
        while self.read(CHUNK):
            pass
        return self.h.hexdigest()


def norm(name):
    while name.startswith("./"):
        name = name[2:]
    return name.strip("/")


def file_hash(f):
    h = hashlib.sha256()
    for chunk in iter(lambda: f.read(CHUNK), b""):
        h.update(chunk)
    return h.hexdigest()


def tar_events(fileobj):
    """A layer tar as an ordered list of (op, path, value)."""
    events = []
    with tarfile.open(fileobj=fileobj, mode="r|*") as t:
        for e in t:
            p = norm(e.name)
            base, parent = os.path.basename(p), os.path.dirname(p)
            if base == ".wh..wh..opq":
                events.append(("opaque", parent, None))
            elif base.startswith(".wh."):
                events.append(("whiteout", os.path.join(parent, base[4:]), None))
            elif e.isreg():
                events.append(("file", p, (file_hash(t.extractfile(e)), e.size)))
            elif e.islnk():
                events.append(("link", p, norm(e.linkname)))
            else:
                events.append(("other", p, None))
    return events


def is_layer(head):
    # An empty layer (a RUN that changed nothing) is a tar of zero blocks only, with no
    # "ustar" header; Docker's own storage (not containerd's) saves it uncompressed.
    return (head[:2] == b"\x1f\x8b" or head[:4] == b"\x28\xb5\x2f\xfd" or head[257:262] == b"ustar"
            or (len(head) >= 512 and not head[:512].strip(b"\0")))


def stream(cmd):
    try:
        return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        raise DockerError(f"cannot run docker: {exc}") from exc


def finish(proc, what):
    proc.stdout.close()
    err = proc.stderr.read().decode(errors="replace").strip()
    if proc.wait() != 0:
        raise DockerError(f"{what} failed: {err.splitlines()[-1] if err else 'exit ' + str(proc.returncode)}")


def read_layers(image):
    """{path: (sha256, size)} the image says, plus the blob/format problems found."""
    proc = stream(["docker", "save", image])
    blobs, manifest, problems = {}, None, []
    try:
        with tarfile.open(fileobj=proc.stdout, mode="r|") as outer:
            for m in outer:
                if not m.isreg():
                    continue
                f = outer.extractfile(m)
                if m.name == "manifest.json":
                    manifest = json.load(f)
                    continue
                r = HashingReader(f)
                head = f.peek(512) if hasattr(f, "peek") else b""
                events = None
                if is_layer(head):
                    events = zstd_events(r) if head[:4] == b"\x28\xb5\x2f\xfd" else tar_events(r)
                got = r.drain()
                name = os.path.basename(m.name)
                if m.name.startswith("blobs/sha256/") and got != name:
                    problems.append(f"layer blob {name[:12]} does not hash to its name")
                blobs[m.name] = events
    except tarfile.TarError as exc:
        proc.kill()
        raise DockerError(f"docker save {image} produced an unreadable archive: {exc}") from exc
    finish(proc, f"docker save {image}")
    if not manifest:
        raise DockerError(f"docker save {image} carried no manifest.json")
    files = {}
    for layer in manifest[0]["Layers"]:
        events = blobs.get(layer)
        if events is None:
            problems.append(f"layer {os.path.basename(layer)[:12]} could not be read")
            continue
        for op, p, v in events:
            if op == "opaque":
                pre = p + "/" if p else ""
                for k in [k for k in files if k.startswith(pre)]:
                    del files[k]
            elif op == "whiteout":
                for k in [k for k in files if k == p or k.startswith(p + "/")]:
                    del files[k]
            elif op == "file":
                files[p] = ("f", v)
            elif op == "link":
                files[p] = ("l", v)
            else:
                files.pop(p, None)
    return resolve(files), problems


def zstd_events(r):
    """A zstd layer, decompressed by the zstd binary (python 3.12 has no zstd)."""
    if not shutil.which("zstd"):
        raise DockerError("a layer is zstd-compressed and this host has no zstd to read it")
    proc = subprocess.Popen(["zstd", "-dc"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def feed():
        try:
            for chunk in iter(lambda: r.read(CHUNK), b""):
                proc.stdin.write(chunk)
        except BrokenPipeError:
            pass
        finally:
            proc.stdin.close()

    t = threading.Thread(target=feed)
    t.start()
    events = tar_events(proc.stdout)
    proc.stdout.read()
    t.join()
    proc.wait()
    return events


def resolve(files):
    out = {}
    for p, v in files.items():
        hops = 0
        while v is not None and v[0] == "l" and hops < 40:
            v = files.get(v[1])
            hops += 1
        if v is not None and v[0] == "f":
            out[p] = v[1]
    return out


def read_rootfs(image):
    name = f"taranac-image-verify-{uuid.uuid4().hex[:12]}"
    created = subprocess.run(
        ["docker", "create", "--name", name, "--network", "none", "--pull", "never",
         "--entrypoint", "/taranac-image-verify", image],
        capture_output=True, text=True,
    )
    if created.returncode != 0:
        raise DockerError(f"docker create {image} failed: {created.stderr.strip()}")
    try:
        proc = stream(["docker", "export", name])
        files = {}
        try:
            with tarfile.open(fileobj=proc.stdout, mode="r|") as t:
                for e in t:
                    p = norm(e.name)
                    if e.isreg():
                        files[p] = ("f", (file_hash(t.extractfile(e)), e.size))
                    elif e.islnk():
                        files[p] = ("l", norm(e.linkname))
        except tarfile.TarError as exc:
            proc.kill()
            raise DockerError(f"docker export of {image} is unreadable: {exc}") from exc
        finish(proc, f"docker export of {image}")
        return resolve(files)
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True)


def mib(n):
    return f"{n / 1048576:.1f} MiB" if n >= 1048576 else f"{n} bytes"


def verify(image):
    """[] when intact, else the differences, worst first."""
    want, problems = read_layers(image)
    have = read_rootfs(image)
    for p, (h, size) in sorted(want.items()):
        if p in OWN_MOUNTS:
            continue
        if p not in have:
            problems.append(f"/{p} is missing")
        elif have[p][0] != h:
            got = have[p][1]
            problems.append(f"/{p} is {mib(got)} on disk, {mib(size)} in the image" if got != size
                            else f"/{p} has other contents than the image ({mib(size)})")
    return problems


def image_id(image):
    r = subprocess.run(["docker", "image", "inspect", "--format", "{{.Id}}", image], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def containers_of(iid):
    """[(name, running)] of every container created from the image."""
    r = subprocess.run(["docker", "ps", "-a", "--filter", f"ancestor={iid}", "--format", "{{.Names}}\t{{.State}}"],
                       capture_output=True, text=True)
    rows = [line.split("\t") for line in r.stdout.splitlines() if line.strip()]
    return [(n, s == "running") for n, s in rows]


def tags_of(image):
    r = subprocess.run(["docker", "image", "inspect", "--format", "{{json .RepoTags}}", image],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return []
    try:
        return json.loads(r.stdout) or []
    except ValueError:
        return []


def last_line(r, fallback):
    return (r.stderr.strip().splitlines() or [fallback])[-1]


def keep_copy(image, path):
    """The image's own layers (hashed during the check) into a file: the copy a cure loads."""
    refs = tags_of(image) or [image]
    r = subprocess.run(["docker", "save", "-o", path, *refs], capture_output=True, text=True)
    if r.returncode != 0:
        try:
            os.unlink(path)
        except OSError:
            pass
        return last_line(r, "docker save failed")
    return ""


def registry_serves(image):
    """'' when the registry answers for the image now — asked BEFORE anything is removed."""
    r = subprocess.run(["docker", "manifest", "inspect", "--insecure", image], capture_output=True, text=True)
    return "" if r.returncode == 0 else last_line(r, "the registry did not answer")


def retag(image):
    # A pull by digest leaves the image untagged; give the pinned content its tag back,
    # as preload-images.sh does — the HA tools run it by name:tag.
    if "@sha256:" in image:
        name_tag, digest = image.split("@", 1)
        if ":" in name_tag.rsplit("/", 1)[-1]:
            subprocess.run(["docker", "tag", f"{name_tag.rsplit(':', 1)[0]}@{digest}", name_tag], capture_output=True)


def restore(image, source):
    kind, where = source
    if kind == "load":
        r = subprocess.run(["docker", "load", "-q", "-i", where], capture_output=True, text=True)
    else:
        r = subprocess.run(["docker", "pull", "-q", where], capture_output=True, text=True)
    if r.returncode != 0:
        return last_line(r, f"docker {kind} failed")
    retag(image)
    return ""


def say(msg):
    print(msg, file=sys.stderr, flush=True)


def report_broken(image, problems):
    say(f"✗ {image} is damaged on this host — its files differ from the image's own layers:")
    for p in problems[:5]:
        say(f"      {p}")
    if len(problems) > 5:
        say(f"      … and {len(problems) - 5} more")


def cure_text(image, running=()):
    lines = []
    if running:
        lines.append(f"  It is in use by the running container(s) {', '.join(running)} — stop them first:")
        lines.append(f"      docker stop {' '.join(running)}")
    lines += [
        "  Keep a copy of its layers FIRST (they are intact when only the unpacked files are damaged),",
        "  then remove every container of the image and the image itself, and load the copy:",
        f"      docker save -o /var/tmp/image.tar {image}",
        f"      docker rm -f $(docker ps -aq --filter ancestor={image}) 2>/dev/null; docker rmi -f {image}",
        "      docker load -i /var/tmp/image.tar",
        "  When the copy cannot be saved: on a host whose copy passes this check,",
        f"      docker save {image} | ssh <this host> docker load",
    ]
    return "\n".join(lines)


def repair(broken, tmp):
    """Replace every damaged image — a replacement in hand BEFORE anything is removed.

    1. a source for each: a copy of its own layers (`docker save`, the blobs whose hashes
       the check just verified), or, when that cannot be made or the blobs are damaged
       too, a registry that answers for it now. No source → it is not touched.
    2. only then every damaged image with a source is removed, its stopped containers
       first — all of them before any comes back, so two images sharing a damaged
       layer cannot hand it to each other;
    3. each comes back from its source and is read again.
    """
    work = tempfile.mkdtemp(prefix="taranac-image-verify.", dir=tmp if os.path.isdir(tmp) else None)
    try:
        ready, refused = {}, {}
        for n, (img, problems) in enumerate(broken.items()):
            report_broken(img, problems)
            iid = image_id(img)
            rows = containers_of(iid) if iid else []
            running = [c for c, up in rows if up]
            if running:
                refused[img] = cure_text(img, running)
                continue
            why = ""
            if not any("does not hash" in p or "could not be read" in p for p in problems):
                path = os.path.join(work, f"{n}.tar")
                why = keep_copy(img, path)
                if not why:
                    ready[img] = (("load", path), iid, rows)
                    say(f"  kept a copy of its layers ({mib(os.path.getsize(path))}) to replace it from.")
                    continue
            else:
                why = "its layers are damaged too"
            reg = registry_serves(img)
            if not reg:
                ready[img] = (("pull", img), iid, rows)
                say(f"  no local copy ({why}); the registry serves it — it will be downloaded again.")
                continue
            refused[img] = (f"  Nothing was removed: no replacement could be had first — a copy of its layers"
                            f" ({why}), nor the registry ({reg}).\n" + cure_text(img))

        for img, (_, iid, rows) in ready.items():
            for c, _ in rows:
                subprocess.run(["docker", "rm", "-f", c], capture_output=True)
            subprocess.run(["docker", "rmi", "-f", iid or img], capture_output=True)
            held = f" and its stopped container(s) {', '.join(c for c, _ in rows)}" if rows else ""
            say(f"  removed {img}{held}.")

        for img, (source, _, _) in ready.items():
            how = "loaded from the copy" if source[0] == "load" else "downloaded again"
            err = restore(img, source)
            if err and source[0] == "load":
                err2 = registry_serves(img) or restore(img, ("pull", img))
                if not err2:
                    err, how = "", "downloaded again (the copy did not load: " + err + ")"
            if err:
                say(f"✗ {img} could not be brought back: {err}")
                say(cure_text(img))
                continue
            try:
                problems = verify(img)
            except DockerError as exc:
                say(f"✗ {img} was {how} but could not be checked: {exc}")
                continue
            if problems:
                report_broken(img, problems)
                say(f"  It is still damaged after it was {how}: another image or container shares the"
                    " damaged layer, or this host's disk or Docker store is at fault.")
                continue
            say(f"✓ {img} {how} and intact.")
            print(f"repaired {img}", flush=True)
            del broken[img]
        for text in refused.values():
            say(text)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description="Verify that images' unpacked files match their layers.")
    ap.add_argument("--repair", action="store_true", help="replace every damaged image from a copy of its layers")
    ap.add_argument("--tmp", default=os.environ.get("TARANAC_IMAGE_TMP", "/var/tmp"),
                    help="where the copies are kept while an image is replaced (default /var/tmp)")
    ap.add_argument("--jobs", type=int, default=min(3, os.cpu_count() or 1))
    ap.add_argument("images", nargs="+")
    a = ap.parse_args()
    images = list(dict.fromkeys(a.images))

    def check(img):
        try:
            return img, verify(img), None
        except DockerError as exc:
            return img, None, str(exc)

    with ThreadPoolExecutor(max_workers=max(1, a.jobs)) as pool:
        results = list(pool.map(check, images))

    errors = [(i, e) for i, _, e in results if e]
    broken = {i: p for i, p, _ in results if p}
    for i, p, e in results:
        if not e:
            print(f"{'BROKEN' if p else 'ok'} {i}", flush=True)
    for i, e in errors:
        say(f"✗ {i} could not be checked: {e}")

    if broken and a.repair:
        repair(broken, a.tmp)
    else:
        for img, problems in broken.items():
            report_broken(img, problems)
            say(cure_text(img))

    if errors:
        return 2
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
