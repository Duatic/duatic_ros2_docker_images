#!/usr/bin/env bash
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

set -euo pipefail

# Make the Duatic apt archive a dependency source of an image: for its build, and for apt and
# rosdep in its containers afterwards.
#
#   duatic_archive.sh add <keyring> <channels> [<versions>]
#   duatic_archive.sh record
#   duatic_archive.sh refresh
#
# add      makes the archive's <codename>-<channel> suites, for the image's Ubuntu codename and
#          each of the space-separated <channels>, an apt source signed by <keyring>, the
#          archive's public key (config/duatic-archive.gpg), which must stay where it is. apt
#          takes a package from the first channel that holds it, whatever its version, except for
#          a package <versions> names: a file record wrote, whose versions apt installs exactly.
#          It maps every package the archive publishes for $ROS_DISTRO as a rosdep key, ahead of
#          the public rosdep index. The caller runs apt-get update and the installers next.
# record   writes the versions of the archive packages installed to
#          /etc/duatic/archive-versions.txt and drops the version pins of add, so a container can
#          install a newer one by hand. The source, the channel order and the mapping stay. Each
#          installed archive package with a shared library that does not link against the others,
#          built against another version of a dependency than the one installed, goes to
#          /etc/duatic/unresolved-rosdep.txt as "link: <package>", a failed install for the gate.
# refresh  maps the packages the configured source publishes now, for duatic-deps in a container.
#
# A Debian name maps to the key it was built from: ros-<distro>-<name> to the ROS package <name>,
# and a name without the ros- prefix to the system package (duatic_package_kind system) of that
# name, both with every "-" as "_". A system package wins over a ROS package of the same name.

URL=https://apt.duatic.com
SOURCE=/etc/apt/sources.list.d/duatic-archive.sources
MAPPING=/etc/duatic/archive-rosdep.yaml
# One "<package> <version>" per line.
VERSIONS=/etc/duatic/archive-versions.txt
PIN=/etc/apt/preferences.d/duatic-archive
# What duatic-rosdep-install records and duatic-deps --gate fails on.
UNRESOLVED=/etc/duatic/unresolved-rosdep.txt
# Above the default 500 of every other suite, so the first channel wins over a higher version
# elsewhere.
PREFER=/etc/apt/preferences.d/duatic-archive-channel
# After 10-local.list, ahead of the public index in 20-default.list.
ROSDEP_LIST=/etc/ros/rosdep/sources.list.d/15-duatic-archive.list
# ID and VERSION_CODENAME of the image's Ubuntu release.
# shellcheck source=/dev/null
. /etc/os-release

# Write stdin, rosdep entries one per line, as the mapping; {} when there is none, since rosdep
# requires a YAML mapping.
save_mapping() {
    cat >"$MAPPING.new"
    [[ -s "$MAPPING.new" ]] || echo '{}' >"$MAPPING.new"
    mv "$MAPPING.new" "$MAPPING"
}

# map <sources file>: write the mapping of every package the archive suites in it publish.
map() {
    local sources="$1" tmp debs deb name
    local -A deb_of=()
    tmp=$(mktemp -d)
    # Removed also when the archive cannot be reached; expanded now, since tmp is local.
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
    # Readable by _apt, which apt-get update downloads as.
    chmod 755 "$tmp"
    mkdir -p "$tmp/sources" "$tmp/lists/partial" "$tmp/cache/archives/partial"
    cp "$sources" "$tmp/sources/duatic-archive.sources"
    # The archive on its own, without the system's sources or installed packages, so the mapping
    # names only what it publishes.
    local alone=(-o Dir::Etc::SourceList=/dev/null -o Dir::Etc::SourceParts="$tmp/sources"
        -o Dir::State::Lists="$tmp/lists" -o Dir::Cache="$tmp/cache" -o Dir::State::status=/dev/null)
    apt-get update -qq --error-on=any "${alone[@]}"
    mapfile -t debs < <(apt-cache "${alone[@]}" dumpavail | sed -n 's/^Package: //p' | sort -u)

    # Keyed by the name the key is derived from; system packages last, so they win.
    for deb in "${debs[@]}"; do
        [[ "$deb" == "ros-${ROS_DISTRO}-"* ]] || continue
        deb_of[${deb#"ros-${ROS_DISTRO}-"}]="$deb"
    done
    for deb in "${debs[@]}"; do
        [[ "$deb" == ros-* ]] || deb_of[$deb]="$deb"
    done
    mkdir -p "$(dirname "$MAPPING")"
    for name in "${!deb_of[@]}"; do
        printf '%s: {%s: {%s: [%s]}}\n' "${name//-/_}" "$ID" "$VERSION_CODENAME" "${deb_of[$name]}"
    done | LC_ALL=C sort | save_mapping
    echo "yaml file://${MAPPING}" >"$ROSDEP_LIST"
    echo "duatic_archive: ${#deb_of[@]} rosdep keys mapped for ${ROS_DISTRO}."
}

# add <keyring> <channels> <versions or empty>: see the header.
add() {
    local keyring="$1" versions="$3" channels suites=() channel
    read -r -a channels <<<"$2"
    for channel in "${channels[@]}"; do suites+=("${VERSION_CODENAME}-${channel}"); done
    printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: main\nSigned-By: %s\n' \
        "$URL" "${suites[*]}" "$keyring" >"$SOURCE"
    map "$SOURCE"
    if [[ ${#suites[@]} -gt 1 ]]; then
        printf 'Package: *\nPin: release n=%s\nPin-Priority: 600\n' "${suites[0]}" >"$PREFER"
    fi
    if [[ -n "$versions" ]]; then
        # Above 1000, so apt installs exactly that version, a lower one included.
        awk '{ printf "Package: %s\nPin: version %s\nPin-Priority: 1001\n\n", $1, $2 }' \
            "$versions" >"$PIN"
        echo "duatic_archive: pinned to the versions in ${versions}:"
        cat "$versions"
    fi
    echo "duatic_archive: ${URL} ${suites[*]}."
}

# misses <package> <library path>: print what the shared libraries of an installed package miss,
# undefined symbols and libraries not found.
misses() {
    local lib
    while read -r lib; do
        [[ "$lib" =~ /lib[^/]*\.so(\.[0-9]+)*$ && -f "$lib" && ! -L "$lib" ]] || continue
        LD_LIBRARY_PATH="$2" ldd -r "$lib" 2>&1 | grep -E 'undefined symbol|not found' || true
    done < <(dpkg -L "$1")
}

# record: see the header.
record() {
    local deb missed ldpath
    # The installed packages whose deb a mapping entry names between brackets.
    dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' |
        awk 'NR == FNR { deb[$0]; next } $1 == "ii" && ($2 in deb) { print $2, $3 }' \
            <(sed -n 's/.*\[\(.*\)\].*/\1/p' "$MAPPING") - >"$VERSIONS"
    rm -f "$PIN"
    echo "duatic_archive: installed from the archive:"
    cat "$VERSIONS"
    # The library path of the ROS installation, which the archive's libraries are found on.
    ldpath=$(env -i bash -c ". /opt/ros/${ROS_DISTRO}/setup.bash && printf %s \"\$LD_LIBRARY_PATH\"")
    while read -r deb _; do
        missed=$(misses "$deb" "$ldpath")
        [[ -n "$missed" ]] || continue
        echo "link: $deb" >>"$UNRESOLVED"
        echo "duatic_archive: ${deb} does not link against the installed packages:" >&2
        c++filt <<<"$missed" | sed 's/^/  /' >&2
    done <"$VERSIONS"
}

case "${1:-}" in
    add)
        [[ $# -eq 3 || $# -eq 4 ]] || {
            echo "Usage: $(basename "$0") add <keyring> <channels> [<versions>]" >&2
            exit 2
        }
        add "$2" "$3" "${4:-}"
        ;;
    record) record ;;
    refresh) map "$SOURCE" ;;
    *)
        echo "Usage: $(basename "$0") add <keyring> <channels> [<versions>] | record | refresh" >&2
        exit 2
        ;;
esac
