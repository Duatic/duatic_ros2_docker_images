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

# Make the Duatic apt archive a dependency source for one image build, then take it away again,
# keeping only what the image installed from it resolvable for rosdep.
#
#   duatic_archive.sh add <keyring> <channels> [<versions>]
#   duatic_archive.sh remove
#
# add      makes the archive's <codename>-<channel> suites, for the image's Ubuntu codename and
#          each of the space-separated <channels>, an apt source signed by <keyring>. apt takes
#          the highest version any of them holds, except for a package <versions> names: a file
#          remove wrote, whose versions apt installs exactly. It maps every package the archive
#          publishes for $ROS_DISTRO as a rosdep key, ahead of the public rosdep index. The caller
#          runs apt-get update and the installers next.
# remove   restricts the mapping to the packages installed, so rosdep keeps resolving those,
#          records their versions in /etc/duatic/archive-versions.txt, and removes the apt source
#          and the pins: apt never installs or upgrades a Duatic package in the image afterwards.
#          The caller deletes the apt lists.
#
# A Debian name maps to the key it was built from: ros-<distro>-<name> to the ROS package <name>,
# and a name without the ros- prefix to the system package (duatic_package_kind system) of that
# name, both with every "-" as "_". A system package wins over a ROS package of the same name.
#
# <keyring> is the archive's public key, config/duatic-archive.gpg. apt reads it from there for
# as long as the source exists, so a bind mount of the build RUN keeps it out of every layer.

URL=https://apt.duatic.com
SOURCE=/etc/apt/sources.list.d/duatic-archive.sources
MAPPING=/etc/duatic/archive-rosdep.yaml
# One "<package> <version>" per line.
VERSIONS=/etc/duatic/archive-versions.txt
PIN=/etc/apt/preferences.d/duatic-archive
# After 10-local.list, ahead of the public index in 20-default.list.
ROSDEP_LIST=/etc/ros/rosdep/sources.list.d/15-duatic-archive.list

# Write stdin, rosdep entries one per line, as the mapping; {} when there is none, since rosdep
# requires a YAML mapping.
save_mapping() {
    cat >"$MAPPING.new"
    [[ -s "$MAPPING.new" ]] || echo '{}' >"$MAPPING.new"
    mv "$MAPPING.new" "$MAPPING"
}

# add <keyring> <channels> <versions or empty>: see the header.
add() {
    local keyring="$1" versions="$3" channels suites=() channel debs deb name tmp
    local -A deb_of=()
    read -r -a channels <<<"$2"
    # shellcheck source=/dev/null
    . /etc/os-release
    for channel in "${channels[@]}"; do suites+=("${VERSION_CODENAME}-${channel}"); done

    tmp=$(mktemp -d)
    # Readable by _apt, which apt-get update downloads as.
    chmod 755 "$tmp"
    mkdir -p "$tmp/sources" "$tmp/lists/partial" "$tmp/cache/archives/partial"
    printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: main\nSigned-By: %s\n' \
        "$URL" "${suites[*]}" "$keyring" >"$tmp/sources/duatic-archive.sources"
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
    cp "$tmp/sources/duatic-archive.sources" "$SOURCE"
    if [[ -n "$versions" ]]; then
        # Above 1000, so apt installs exactly that version, a lower one included.
        awk '{ printf "Package: %s\nPin: version %s\nPin-Priority: 1001\n\n", $1, $2 }' \
            "$versions" >"$PIN"
        echo "duatic_archive: pinned to the versions in ${versions}:"
        cat "$versions"
    fi
    rm -rf "$tmp"
    echo "duatic_archive: ${URL} ${suites[*]}, ${#deb_of[@]} rosdep keys mapped for ${ROS_DISTRO}."
}

# remove: see the header.
remove() {
    # An entry names its deb between brackets.
    dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1 == "ii" { print "[" $2 "]" }' |
        { grep -F -f - "$MAPPING" || true; } | save_mapping
    sed -n 's/.*\[\(.*\)\].*/\1/p' "$MAPPING" |
        xargs -r dpkg-query -W -f='${Package} ${Version}\n' >"$VERSIONS"
    rm -f "$SOURCE" "$PIN"
    # Drops the packages not installed from rosdep's cache.
    rosdep update
    echo "duatic_archive: source removed, the packages installed remain rosdep keys:"
    cat "$VERSIONS"
}

case "${1:-}" in
    add)
        [[ $# -eq 3 || $# -eq 4 ]] || {
            echo "Usage: $(basename "$0") add <keyring> <channels> [<versions>]" >&2
            exit 2
        }
        add "$2" "$3" "${4:-}"
        ;;
    remove) remove ;;
    *)
        echo "Usage: $(basename "$0") add <keyring> <channels> [<versions>] | remove" >&2
        exit 2
        ;;
esac
