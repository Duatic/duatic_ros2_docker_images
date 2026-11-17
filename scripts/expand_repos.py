#!/usr/bin/env python3
# Copyright 2026 Duatic AG
#
# Redistribution and use in source and binary forms, with or without modification, are permitted provided that
# the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this list of conditions, and
#    the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions, and
#    the following disclaimer in the documentation and/or other materials provided with the distribution.
#
# 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or
#    promote products derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
# PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
# TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

"""Resolve the repository set a workspace is built from, every git repository pinned to a commit.

REPOS_FILE is the root repository's repos.list (missing: the root builds on its own). It is merged
with every repos.list its git repositories carry, recursively, each read at the version that entry
names. Two lists naming the same repository key must agree on its type, url and version, and one
url may not appear under two keys; either is an error that names both lists. Each git repository
is pinned to the commit its version names right now.

The merged lists declare where each package comes from. Only the packages a package.xml of the
root (any depth below CHECKOUT) depends on, directly or through other packages built, are built,
and only the repositories carrying one of them are written; every other repository is left out of
all three repos files. Every *depend tag counts, test and doc dependencies included.

Usage:  expand_repos.py REPOS_FILE --root NAME URL COMMIT BRANCH --checkout CHECKOUT --out DIR
                        [--locked]

Writes, ready for `vcs import`:
  DIR/upstream.repos         the pinned repositories, without the root: what the build imports
  DIR/sources.lock.repos     the root at COMMIT and the pinned repositories: the exact source pin
  DIR/sources.repos          the root at BRANCH and every repository at the version its list
                             names: an editable, branch-tracking manifest
  DIR/unused_packages.txt    one line per package of upstream.repos that is not built: its
                             directory relative to the directory upstream.repos is imported into

--locked takes REPOS_FILE as the sources.lock.repos of an earlier build, to reproduce it: nothing
is expanded or pinned again, the root (matched by URL) is left out of upstream.repos, and both
manifests repeat REPOS_FILE.
"""

import argparse
import os
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from collections import deque

import yaml

NESTED = "repos.list"
MANIFEST = "package.xml"
UNUSED = "unused_packages.txt"


def normalized_url(url):
    """The url without case, a trailing slash or .git, so spellings of one repository compare equal."""
    url = url.rstrip("/").lower()
    return url[: -len(".git")] if url.endswith(".git") else url


def spec(entry):
    """What two lists naming the same repository key have to agree on."""
    return entry.get("type"), normalized_url(entry.get("url", "")), str(entry.get("version", ""))


def repositories(text):
    """The repositories mapping of a repos file's text."""
    return (yaml.safe_load(text) or {}).get("repositories") or {}


def package_deps(text, where):
    """The package a package.xml declares, and every package its *depend tags name.

    Args:
        text: the package.xml content.
        where: names the file in the error when it cannot be read.

    Returns:
        (name, deps), deps a set of package names.
    """
    try:
        manifest = ET.fromstring(text)
        name = manifest.findtext("name").strip()
    except (ET.ParseError, AttributeError) as e:
        raise SystemExit(f"{where}: no package name readable: {e}")
    return name, {e.text.strip() for e in manifest if e.tag.endswith("depend") and e.text}


def resolve(url, version):
    """The commit a git repository's version names, its repos.list text and its packages there.

    Args:
        url: the repository to fetch from.
        version: a branch, tag or commit.

    Returns:
        (commit, text, packages): text None when the repository carries no repos.list, packages
        every package.xml in the tree as its package name mapped to (directory, deps), the
        directory relative to the repository root and deps the packages it depends on.
    """
    with tempfile.TemporaryDirectory() as tmp:

        def git(*args):
            """Run git in the scratch repository, failing with the fetched url in the message."""
            r = subprocess.run(["git", *args], cwd=tmp, capture_output=True, text=True)
            if r.returncode:
                raise SystemExit(f'{url}@{version}: git {" ".join(args)}: {r.stderr.strip()}')
            return r.stdout

        git("init", "-q")
        git("remote", "add", "origin", url)
        git("config", "remote.origin.promisor", "true")
        git("config", "remote.origin.partialclonefilter", "blob:none")
        git("fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", version)
        commit = git("rev-parse", "FETCH_HEAD").strip()
        listing = git("ls-tree", "-r", "-z", "FETCH_HEAD").split("\0")[:-1]
        objects = {
            path: meta.split()[2] for meta, path in (entry.split("\t", 1) for entry in listing)
        }
        manifests = {p: o for p, o in objects.items() if os.path.basename(p) == MANIFEST}
        wanted = [*manifests.values(), *([objects[NESTED]] if NESTED in objects else [])]
        if wanted:
            git(
                "-c", "fetch.negotiationAlgorithm=noop",
                "fetch", "-q", "--no-write-fetch-head", "origin", *wanted,
            )
        packages = {}
        for path, obj in manifests.items():
            package, deps = package_deps(git("cat-file", "blob", obj), f"{url}@{version}:{path}")
            packages[package] = os.path.dirname(path), deps
        text = git("cat-file", "blob", objects[NESTED]) if NESTED in objects else None
        return commit, text, packages


def expand(repos, root_url):
    """Merge repos with the lists its git repositories carry, pinning each git repository.

    Args:
        repos: the repositories mapping of the root's repos.list.
        root_url: the root repository's normalized url, left out wherever a list names it.

    Returns:
        (merged, pinned, provides): the repositories at the versions their lists name, the same
        with every git repository's version replaced by its commit, and per git repository the
        packages it carries (see resolve).
    """
    queue = deque([(NESTED, repos)])
    merged, pinned, provides, named_by, key_of_url = {}, {}, {}, {}, {}
    while queue:
        origin, repos = queue.popleft()
        for key, entry in repos.items():
            if normalized_url(entry.get("url", "")) == root_url:
                continue
            if key in merged:
                if spec(merged[key]) != spec(entry):
                    first, second = merged[key], entry
                    raise SystemExit(
                        f"conflicting entries for {key}:\n"
                        f'  {named_by[key]}: {first.get("url")} @ {first.get("version")}\n'
                        f'  {origin}: {second.get("url")} @ {second.get("version")}'
                    )
                continue
            url = normalized_url(entry.get("url", ""))
            if url in key_of_url:
                other = key_of_url[url]
                raise SystemExit(
                    f'{entry.get("url")} is named both {other} ({named_by[other]}) and {key} ({origin})'
                )
            merged[key], named_by[key], key_of_url[url] = entry, origin, key
            if entry.get("type") != "git":
                pinned[key] = entry
                continue
            version = str(entry.get("version") or "HEAD")
            commit, text, provides[key] = resolve(entry["url"], version)
            pinned[key] = {**entry, "version": commit}
            if text is not None:
                queue.append((f"{key}/{NESTED}", repositories(text)))
    return merged, pinned, provides


def local_deps(directory):
    """Every package the package.xml files of a local checkout depend on.

    Args:
        directory: the checkout, searched at any depth.

    Returns:
        The set of package names.
    """
    deps = set()
    for dirpath, _, filenames in os.walk(directory):
        if MANIFEST in filenames:
            path = os.path.join(dirpath, MANIFEST)
            with open(path) as f:
                deps |= package_deps(f.read(), path)[1]
    return deps


def needed(deps, provides):
    """The packages deps reach, directly or through the dependencies of the packages reached.

    Args:
        deps: package names to start from.
        provides: per repository key, its packages as resolve returns them.

    Returns:
        Each package reached mapped to the key of the repository carrying it. A package no
        repository carries is left to rosdep.
    """
    owner = {}
    for key, packages in provides.items():
        for name in packages:
            if name in owner:
                raise SystemExit(f"package {name} is in both {owner[name]} and {key}")
            owner[name] = key
    found, queue = {}, deque(deps)
    while queue:
        name = queue.popleft()
        if name in owner and name not in found:
            found[name] = owner[name]
            queue.extend(provides[owner[name]][name][1])
    return found


def write_unused(path, found, provides):
    """Write the directories of the packages not found, in the repositories found reaches.

    Args:
        path: the file to write, one directory per line, each a repository key joined with the
            package's directory in it.
        found: the packages built, as needed returns them.
        provides: per repository key, its packages as resolve returns them.
    """
    unused = sorted(
        os.path.join(key, directory)
        for key in set(found.values())
        for name, (directory, _) in provides[key].items()
        if name not in found
    )
    with open(path, "w") as f:
        f.writelines(f"{d}\n" for d in unused)


def write(path, repos):
    """Write a repositories mapping as a repos file."""
    with open(path, "w") as f:
        yaml.safe_dump({"repositories": repos}, f, sort_keys=False, default_flow_style=False)


def main():
    """Write the repos files and unused_packages.txt, or exit with the first conflict found."""
    ap = argparse.ArgumentParser()
    ap.add_argument("repos_file")
    ap.add_argument("--root", nargs=4, required=True, metavar=("NAME", "URL", "COMMIT", "BRANCH"))
    ap.add_argument("--checkout", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--locked", action="store_true")
    args = ap.parse_args()
    name, url, commit, branch = args.root
    root_url = normalized_url(url)

    repos = {}
    if os.path.exists(args.repos_file):
        with open(args.repos_file) as f:
            repos = repositories(f.read())

    if args.locked:
        upstream = {k: e for k, e in repos.items() if normalized_url(e.get("url", "")) != root_url}
        provides = {
            k: resolve(e["url"], str(e["version"]))[2]
            for k, e in upstream.items()
            if e.get("type") == "git"
        }
        found = needed(local_deps(args.checkout), provides)
        write(os.path.join(args.out, "upstream.repos"), upstream)
        write(os.path.join(args.out, "sources.lock.repos"), repos)
        write(os.path.join(args.out, "sources.repos"), repos)
        write_unused(os.path.join(args.out, UNUSED), found, provides)
        return

    merged, pinned, provides = expand(repos, root_url)
    found = needed(local_deps(args.checkout), provides)
    keep = set(found.values())
    merged = {k: e for k, e in merged.items() if k in keep}
    pinned = {k: e for k, e in pinned.items() if k in keep}
    root = {"type": "git", "url": url}
    write(os.path.join(args.out, "upstream.repos"), pinned)
    write(
        os.path.join(args.out, "sources.lock.repos"), {name: {**root, "version": commit}, **pinned}
    )
    write(os.path.join(args.out, "sources.repos"), {name: {**root, "version": branch}, **merged})
    write_unused(os.path.join(args.out, UNUSED), found, provides)


if __name__ == "__main__":
    main()
