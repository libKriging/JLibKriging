#!/usr/bin/env bash
# Point deps/sources.toml at a libKriging commit (default: tip of master).
# Julia counterpart of rlibkriging's `git submodule update --remote` +
# tools/update_submodule_shas.sh, run by libKriging's "Send submodule updates
# to dependent repo" workflow on every push to libKriging master.
#
#   tools/update_sources.sh [libKriging-ref]
#
# * sets libKriging.sha, and the shas of the libKriging submodules the Julia
#   binding needs (read from libKriging's own tree at that commit);
# * if libKriging's version (cmake/version.cmake) changed, also records it and
#   bumps Project.toml to the same version -- so a new JLibKriging version is
#   registered ONLY when libKriging is released. Between two libKriging
#   releases, master keeps following libKriging without registering anything.
#
# Needs curl and either `jq` or python3; GITHUB_TOKEN raises the API rate limit.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=libKriging/libKriging
REF=${1:-master}
API=https://api.github.com
auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
api() { curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" "$API/$1"; }
json() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

SHA=$(api "repos/$REPO/commits/$REF" | json 'd["sha"]')
echo "libKriging $REF -> $SHA"

VERSION=$(curl -fsSL "${auth[@]}" "https://raw.githubusercontent.com/$REPO/$SHA/cmake/version.cmake" | python3 -c '
import re,sys
t=sys.stdin.read()
g=lambda n: re.search(r"^set\(KRIGING_VERSION_%s (\d+)\)$" % n, t, re.M).group(1)
print("%s.%s.%s" % (g("MAJOR"), g("MINOR"), g("PATCH")))')
echo "libKriging version at that commit: $VERSION"

# rewrite the [libKriging] block and each [[dependency]] sha
python3 - "$SHA" "$VERSION" "$REPO" "$REF" <<'PY'
import json, re, subprocess, sys, os, urllib.request
sha, version, repo, ref = sys.argv[1:5]
tok = os.environ.get("GITHUB_TOKEN")
def api(path):
    req = urllib.request.Request("https://api.github.com/" + path,
                                 headers={"Accept": "application/vnd.github+json"})
    if tok: req.add_header("Authorization", "Bearer " + tok)
    return json.load(urllib.request.urlopen(req))
p = "deps/sources.toml"
s = open(p).read()
old_version = re.search(r'^\[libKriging\].*?^version\s*=\s*"([^"]+)"', s, re.M | re.S).group(1)
s = re.sub(r'(^\[libKriging\].*?^)sha\s*=\s*"[0-9a-f]{40}"[^\n]*', r'\g<1>sha  = "%s"   # %s' % (sha, ref), s, count=1, flags=re.M | re.S)
s = re.sub(r'(^\[libKriging\].*?^version\s*=\s*")[^"]+(")', r'\g<1>%s\2' % version, s, count=1, flags=re.M | re.S)
def bump(m):
    path = m.group(1)
    dep = api("repos/%s/contents/%s?ref=%s" % (repo, path, sha))
    return m.group(0)[:m.start(2)-m.start(0)] + dep["sha"] + m.group(0)[m.end(2)-m.start(0):]
s = re.sub(r'path\s*=\s*"([^"]+)"\nrepo\s*=\s*"[^"]+"\nsha\s*=\s*"([0-9a-f]{40})"', bump, s)
open(p, "w").write(s)
if old_version != version:
    q = open("Project.toml").read()
    q = re.sub(r'^version = "[^"]+"', 'version = "%s"' % version, q, count=1, flags=re.M)
    open("Project.toml", "w").write(q)
    print("libKriging %s -> %s: Project.toml bumped" % (old_version, version))
PY
git --no-pager diff --stat -- deps/sources.toml Project.toml || true
