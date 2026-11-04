#!/usr/bin/env bash
# Tags v<version>, pushes the tag, and creates a DRAFT GitHub release with the notarized DMG,
# its SHA-256 file and the dSYM. Usage: scripts/publish-release.sh <version>
#
# Run scripts/release.sh first. Pushing the tag is public; the release stays a draft until
# you check the download and click Publish on GitHub (docs/RELEASING.md).
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "error: $*" >&2; exit 1; }

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version>   (for example: $0 1.0.0)" >&2
    exit 2
fi
version="$1"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.3 (got '$version')"
tag="v$version"

project_version="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' project.yml)"
[[ "$project_version" == "$version" ]] \
    || die "project.yml says MARKETING_VERSION $project_version, not $version"

out=build/release
# A fixed name for releases/latest/download/RaccoonWriter.dmg; see scripts/release.sh.
dmg="$out/RaccoonWriter.dmg"
sha="$dmg.sha256"
dsym="$out/RaccoonWriter-$version.dSYM.zip"
notes="docs/release-notes/$tag.md"
for file in "$dmg" "$sha" "$dsym" "$out/commit"; do
    [[ -f "$file" ]] || die "$file is missing; run scripts/release.sh first"
done
[[ -f "$notes" ]] || die "$notes is missing; write the release notes and commit them"

command -v gh >/dev/null 2>&1 || die "gh not found: brew install gh"
gh auth status >/dev/null 2>&1 || die "gh is not logged in: gh auth login"

echo "==> Checking the DMG"
(cd "$out" && shasum -a 256 -c "$(basename "$sha")") || die "the DMG does not match its SHA-256 file"
xcrun stapler validate "$dmg" || die "the DMG has no valid notarization ticket"
assessment="$(spctl --assess --type open --context context:primary-signature -vv "$dmg" 2>&1)" || true
grep -q 'source=Notarized Developer ID' <<<"$assessment" \
    || { echo "$assessment" >&2; die "Gatekeeper does not accept the DMG as notarized"; }

echo "==> Checking git"
[[ -z "$(git status --porcelain)" ]] || die "the working tree has uncommitted changes"
[[ "$(git symbolic-ref --short HEAD)" == main ]] || die "not on main"
head="$(git rev-parse HEAD)"
[[ "$(cat "$out/commit")" == "$head" ]] \
    || die "the DMG was built from $(cat "$out/commit"), but HEAD is $head; rerun scripts/release.sh"
git fetch --quiet origin main
[[ "$(git rev-parse origin/main)" == "$head" ]] || die "HEAD is not pushed to origin/main; push it first"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    die "tag $tag already exists locally"
fi
status=0
git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null || status=$?
case $status in
    2) ;;
    0) die "tag $tag already exists on origin" ;;
    *) die "could not list origin's tags (git ls-remote exit $status)" ;;
esac
if gh release view "$tag" >/dev/null 2>&1; then
    die "a GitHub release for $tag already exists"
fi

echo "==> Tagging $tag at ${head:0:12} and pushing it"
git tag -a "$tag" -m "Raccoon Writer $version"
git push origin "refs/tags/$tag"

echo "==> Creating the draft release"
url="$(gh release create "$tag" --draft --verify-tag \
    --title "Raccoon Writer $version" --notes-file "$notes" \
    "$dmg" "$sha" "$dsym")"
echo
echo "Draft release: $url"
echo "Next: download the DMG from the draft in Safari, check it (docs/RELEASING.md), then click Publish."
