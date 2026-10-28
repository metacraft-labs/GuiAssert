#!/usr/bin/env python3
"""GADV-2 gate: no workspace repository imports a module that left GuiAssert.

The video-production modules moved to DemoVideoStudio. This scans every git
repository directly under a workspace directory (default: the parent of this
checkout) for a Nim import of one of them through `gui_assert/`, at a given ref
(default HEAD; `--ref origin/agents` scans what is published), and lists each
one found. It exits 1 when any is found.

    run-gadv2-import-scan.py [--root DIR] [--ref REF]   scan the workspace
    run-gadv2-import-scan.py --self-test                the gate: a planted
        import of gui_assert/media in a scratch repository must turn the scan red,
        and the same repository without it must scan clean
"""
import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

MOVED = ["editor_backend", "media", "speech_synthesis", "speech_synth", "talking_head",
         "avatar_track", "emotive", "artifact_project", "storyboard", "parser", "driver"]
# `import gui_assert/media`, `from gui_assert/talking_head/core import x`,
# `import gui_assert/[media, ocr]`
PATTERN = (r"^\s*(import|from|include)\b.*gui_assert/(\[[^]]*\b(" + "|".join(MOVED) +
           r")\b|(" + "|".join(MOVED) + r")\b)")
SELF = Path(__file__).resolve().parents[2]


def scan_repo(repo, ref):
    r = subprocess.run(["git", "-C", str(repo), "grep", "-nIE", PATTERN, ref, "--", "*.nim", "*.nims"],
                       capture_output=True, text=True)
    hits = [l for l in r.stdout.splitlines() if l]
    return hits


def is_gui_assert(repo):
    # GuiAssert itself (any checkout of it) is the former home, not a consumer
    url = subprocess.run(["git", "-C", str(repo), "remote", "get-url", "origin"],
                         capture_output=True, text=True).stdout.strip()
    return repo.resolve() == SELF or re.search(r"[/:]GuiAssert(\.git)?$", url) is not None


def scan(root, ref):
    found = []
    for repo in sorted(p for p in Path(root).iterdir() if (p / ".git").exists()):
        if is_gui_assert(repo):
            continue
        if subprocess.run(["git", "-C", str(repo), "rev-parse", "-q", "--verify", ref + "^{commit}"],
                          capture_output=True).returncode != 0:
            continue
        found += [f"{repo.name}: {h}" for h in scan_repo(repo, ref)]
    return found


def self_test():
    with tempfile.TemporaryDirectory(prefix="gadv2-scan-") as root:
        repo = Path(root) / "consumer"
        repo.mkdir()
        git = lambda *a: subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True)
        git("init", "-q")
        (repo / "ok.nim").write_text("import gui_assert/ocr\nimport demo_video_studio/media\n")
        git("add", "-A"); git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "clean", "--no-verify")
        clean = scan(root, "HEAD")
        (repo / "planted.nim").write_text("import gui_assert/media\n")
        git("add", "-A"); git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "planted", "--no-verify")
        red = scan(root, "HEAD")
    ok = not clean and len(red) == 1 and "planted.nim" in red[0]
    print(f"clean repository: {len(clean)} found; planted import: {red}")
    print("KILLED   a planted import of gui_assert/media" if ok else "SURVIVED a planted import of gui_assert/media")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=str(SELF.parent))
    ap.add_argument("--ref", default="HEAD")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        sys.exit(self_test())
    found = scan(a.root, a.ref)
    for f in found:
        print(f)
    print(f"{len(found)} import(s) of a moved module")
    sys.exit(1 if found else 0)


if __name__ == "__main__":
    main()
