"""pkgmeta — map a downloaded source file back to the packages that asked for it.

OpenWrt writes tmp/.packageinfo while collecting package metadata. Each block
names the tarball the package downloads (Source:), its licence and its project
URL, so the mapping from a file in dl/ to "who wanted it, under what licence"
is already in the tree and does not need re-deriving from Makefiles.

What is NOT in there: tools/ and toolchain/ (gcc, binutils, musl). Those are
built before any package metadata exists. Their licences come from their own
Makefiles when declared, and are left null when not -- recorded as unknown
rather than guessed, because a wrong licence in a published manifest is a
misstatement about someone else's terms.
"""
import os
import re


def _blocks(path):
    """Yield each package block as a dict of field -> value."""
    cur = {}
    with open(path, errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip():
                if cur:
                    yield cur
                    cur = {}
                continue
            m = re.match(r"^([A-Za-z][A-Za-z0-9-]*): ?(.*)$", line)
            if m:
                # First wins: Description: is followed by indented continuation
                # lines that would otherwise overwrite earlier fields.
                cur.setdefault(m.group(1), m.group(2))
    if cur:
        yield cur


def from_packageinfo(tree):
    """{source filename: {packages, licences, urls, makefiles}} for one tree."""
    return from_packageinfo_file(os.path.join(tree, "tmp", ".packageinfo"))


def from_packageinfo_file(p):
    """As above, from a specific .packageinfo -- normally a snapshot taken while
    a board was collected, because the tree's own copy is rewritten by the next
    prepare."""
    out = {}
    if not os.path.exists(p):
        return out
    for b in _blocks(p):
        # Source: may list several files for one package.
        names = []
        for fn in (b.get("Source") or "").split():
            names.append(fn)
            # Git-sourced packages are indexed here under the full 40-character
            # commit but land in dl/ under an eight-character one, because the
            # archive step sets core.abbrev 8. Registering both is what connects
            # fstools-...~8d377aa6.tar.zst to the package that asked for it.
            m = re.search(r"~([0-9a-f]{40})", fn)
            if m:
                names.append(fn.replace(m.group(1), m.group(1)[:8]))
        for fn in names:
            e = out.setdefault(fn, {"packages": set(), "licences": set(),
                                    "urls": set(), "makefiles": set(),
                                    "versions": set()})
            if b.get("Package"):
                e["packages"].add(b["Package"])
            if b.get("License"):
                e["licences"].add(b["License"])
            if b.get("URL"):
                e["urls"].add(b["URL"])
            if b.get("Source-Makefile"):
                e["makefiles"].add(b["Source-Makefile"])
            if b.get("Version"):
                e["versions"].add(b["Version"])
    return out


_MK_FIELDS = {
    "licence": re.compile(r"^PKG_LICENSE\s*:?=\s*(.+?)\s*$", re.M),
    "name": re.compile(r"^PKG_NAME\s*:?=\s*(.+?)\s*$", re.M),
    "version": re.compile(r"^PKG_VERSION\s*:?=\s*(.+?)\s*$", re.M),
    "source": re.compile(r"^PKG_SOURCE\s*:?=\s*(.+?)\s*$", re.M),
}


def _expand(value, name, version):
    """$(PKG_NAME)/$(PKG_VERSION) only. Anything else is left unexpanded and the
    caller drops it -- a half-expanded filename would match the wrong file."""
    if value is None:
        return None
    for var, val in (("PKG_NAME", name), ("PKG_VERSION", version)):
        if val:
            value = value.replace("$(%s)" % var, val)
    return None if re.search(r"[$(){}]", value) else value


def from_makefiles(tree, subdirs=("tools", "toolchain")):
    """{source filename prefix: {...}} for the trees package metadata skips.

    Matched on PKG_NAME-PKG_VERSION rather than PKG_SOURCE, because PKG_SOURCE
    is usually built from those two through variables this cannot expand
    without running make.
    """
    out = {}
    for sub in subdirs:
        root = os.path.join(tree, sub)
        if not os.path.isdir(root):
            continue
        for dirpath, _, files in os.walk(root):
            # Makefile plus the .mk files beside it: toolchain/gcc keeps
            # PKG_VERSION in common.mk, so reading only Makefile misses gcc and
            # musl -- two of the largest things a source cache has to account
            # for.
            names = [f for f in files if f == "Makefile" or f.endswith(".mk")]
            # A Makefile is not required. toolchain/gcc holds PKG_NAME and the
            # licence in common.mk and keeps its Makefiles in initial/ and
            # final/, so insisting on one here dropped gcc -- the single largest
            # object in the cache -- from attribution entirely.
            if not names:
                continue
            text = ""
            for n in sorted(names):
                try:
                    text += open(os.path.join(dirpath, n), errors="replace").read() + "\n"
                except OSError:
                    pass
            got = {k: (r.search(text).group(1) if r.search(text) else None)
                   for k, r in _MK_FIELDS.items()}
            if not got["name"]:
                continue
            entry = {
                "packages": {got["name"]},
                "licences": {got["licence"]} if got["licence"] else set(),
                "urls": set(),
                "makefiles": {os.path.relpath(os.path.join(dirpath, "Makefile"), tree)},
                "versions": {got["version"]} if got["version"] else set(),
            }
            # Both the bare name and name-version. PKG_SOURCE does not always
            # join them with a hyphen -- fakeroot ships as
            # fakeroot_1.37.1.2.orig.tar.gz -- so a name-version key alone
            # misses it, and with it the licence the Makefile does declare.
            #
            # PKG_SOURCE first where it expands: tools/sstrip downloads
            # ELFkickers-3.2.tar.gz, so no key derived from the package name
            # could ever match its tarball.
            keys = []
            src = _expand(got["source"], got["name"], got["version"])
            if src:
                keys.append(src)
            keys.append(got["name"])
            if got["version"] and not re.search(r"[$(){}]", got["version"]):
                keys.append("%s-%s" % (got["name"], got["version"]))
            for key in keys:
                out.setdefault(key, entry)
    return out


def lookup(filename, by_source, by_prefix):
    """Metadata for one downloaded file, or None.

    Exact Source: match first. Failing that, the longest PKG_NAME-PKG_VERSION
    prefix -- gcc-14.3.0.tar.xz is not any package's Source:, but toolchain/gcc
    declares the two halves of its name.
    """
    if filename in by_source:
        return by_source[filename]
    best = None
    for key, meta in by_prefix.items():
        if filename.startswith(key) and (best is None or len(key) > len(best)):
            best = key
    return by_prefix[best] if best else None
