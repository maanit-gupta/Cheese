#!/bin/zsh
# Cuts a release in one command:
#
#   scripts/release.sh 2.4            bump project.yml, build, package, print the gh command
#   scripts/release.sh 2.4.1 --publish   …and commit the bump, push main, create the GitHub release
#
# Sets MARKETING_VERSION to the new version and adds one to CURRENT_PROJECT_VERSION, then runs
# scripts/package.sh (xcodegen, Release build, codesign check, ditto zip, sha256). The app stays
# signed with the Apple Development identity from project.yml, never ad-hoc: macOS ties Screen
# Recording and Accessibility grants to that signature, and the in-app updater only installs an
# archive signed by the same team as the running copy.
#
# Both assets keep fixed names, so releases/latest/download/Cheese.zip, install.sh and the
# updater (which checks the download against Cheese.zip.sha256) keep working.
set -euo pipefail

cd "${0:A:h}/.."

usage() {
    echo "usage: scripts/release.sh <version> [--publish]   e.g. scripts/release.sh 2.4" >&2
    exit 64
}

VERSION=""
PUBLISH=0
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=1 ;;
        -h|--help) usage ;;
        -*) echo "unknown option: $arg" >&2; usage ;;
        *) [[ -z "$VERSION" ]] || usage; VERSION="$arg" ;;
    esac
done
[[ -n "$VERSION" ]] || usage
VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]]; then
    echo "not a version: $VERSION (expected 2.4 or 2.4.1)" >&2
    exit 64
fi

CURRENT=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\} *$/\1/p' project.yml | head -n 1)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *\([0-9]*\) *$/\1/p' project.yml | head -n 1)
if [[ -z "$CURRENT" || -z "$BUILD" ]]; then
    echo "couldn't find MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml" >&2
    exit 1
fi

# Newer than the current version, comparing part by part with missing parts as 0 (2.4 == 2.4.0).
is_newer() {
    local -a new old
    new=("${(@s:.:)1}") old=("${(@s:.:)2}")
    local i n o
    for i in 1 2 3; do
        n=${new[$i]:-0} o=${old[$i]:-0}
        (( n > o )) && return 0
        (( n < o )) && return 1
    done
    return 1
}
if ! is_newer "$VERSION" "$CURRENT"; then
    echo "$VERSION isn't newer than the current version $CURRENT" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "tag v$VERSION already exists" >&2
    exit 1
fi

if (( PUBLISH )); then
    command -v gh >/dev/null || { echo "--publish needs the GitHub CLI (brew install gh)" >&2; exit 1; }
    [[ "$(git branch --show-current)" == main ]] || { echo "--publish runs from main" >&2; exit 1; }
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        echo "--publish needs a clean working tree (commit or stash first), so the tag matches what was built" >&2
        exit 1
    fi
fi

NEXT_BUILD=$((BUILD + 1))
echo "Cheese $CURRENT ($BUILD) → $VERSION ($NEXT_BUILD)"
sed -i '' \
    -e "s/^\( *MARKETING_VERSION: *\).*$/\1\"$VERSION\"/" \
    -e "s/^\( *CURRENT_PROJECT_VERSION: *\).*$/\1$NEXT_BUILD/" \
    project.yml

scripts/package.sh

BUILT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/ReleaseData/Build/Products/Release/Cheese.app/Contents/Info.plist)
if [[ "$BUILT" != "$VERSION" ]]; then
    echo "the built app says $BUILT, not $VERSION" >&2
    exit 1
fi

GH=(gh release create "v$VERSION" dist/Cheese.zip dist/Cheese.zip.sha256 --title "Cheese $VERSION" --generate-notes)
if (( PUBLISH )); then
    git add project.yml
    git commit -m "Cheese $VERSION"
    git push origin main
    "${GH[@]}" --target main
    echo
    echo "Published Cheese $VERSION. Running copies pick it up within 12 hours, or at once from Check for Updates…"
else
    echo
    echo "project.yml now says $VERSION ($NEXT_BUILD). Commit and push it, then publish with:"
    echo
    echo "  ${(q-)GH[@]}"
fi
