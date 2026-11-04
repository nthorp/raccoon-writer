#!/usr/bin/env bash
# Builds a Developer ID signed, notarized and stapled build/release/RaccoonWriter.dmg.
# The DMG name has no version, so releases/latest/download/RaccoonWriter.dmg always points at
# the newest release (the website's Download button uses it). Keep the name stable.
# Usage: scripts/release.sh [--skip-notarize]
#
# --skip-notarize  Ad-hoc signature, no notarization, output in build/release-adhoc/.
#                  Tests the pipeline without Apple credentials. Not for distribution.
#
# Environment:
#   RACCOONWRITER_SIGN_IDENTITY   codesign identity (name or SHA-1). Default: the only
#                                 "Developer ID Application" identity in the keychain.
#   RACCOONWRITER_NOTARY_PROFILE  notarytool keychain profile. Default: raccoon-writer-notary.
#
# One-time setup and the full release checklist are in docs/RELEASING.md. This script touches
# no disks: hdiutil only creates and mounts an image file. Written for macOS's bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/.."

notarize=1
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) notarize=0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

app=build/RaccoonWriter.app
dsym=build/RaccoonWriter.app.dSYM
shipped_app="Raccoon Writer.app"
entitlements=App/RaccoonWriter.entitlements
profile="${RACCOONWRITER_NOTARY_PROFILE:-raccoon-writer-notary}"

# MARKETING_VERSION in project.yml is the one source of the version.
version="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' project.yml)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "could not read a MARKETING_VERSION like 1.2.3 from project.yml (got '$version')"
tag="v$version"

if (( notarize )); then
    out=build/release
    dmg_name="RaccoonWriter.dmg"
else
    out=build/release-adhoc
    dmg_name="RaccoonWriter-$version-adhoc.dmg"
fi
dmg="$out/$dmg_name"

# ---------------------------------------------------------------------------------------
step "Preflight ($tag)"

for tool in git codesign ditto hdiutil shasum security; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done
if (( notarize )); then
    xcrun --find notarytool >/dev/null 2>&1 || die "xcrun notarytool not found (needs Xcode)"
    xcrun --find stapler >/dev/null 2>&1 || die "xcrun stapler not found (needs Xcode)"
fi

# The tag created later must point at the commit this DMG was built from.
dirty="$(git status --porcelain)" || die "git status failed"
if [[ -n "$dirty" ]]; then
    if (( notarize )); then
        echo "$dirty" >&2
        die "the working tree has uncommitted changes; commit or stash them first"
    fi
    echo "warning: uncommitted changes (allowed with --skip-notarize)"
fi
commit="$(git rev-parse HEAD)"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    die "tag $tag already exists; bump MARKETING_VERSION in project.yml for a new release"
fi

if (( notarize )); then
    identity="${RACCOONWRITER_SIGN_IDENTITY:-}"
    identities="$(security find-identity -v -p codesigning)" || die "security find-identity failed"
    if [[ -z "$identity" ]]; then
        # Lines look like:  1) <SHA-1> "Developer ID Application: Name (TEAMID)"
        matches="$(grep -E '"Developer ID Application: [^"]+"' <<<"$identities" || true)"
        count=0
        [[ -n "$matches" ]] && count="$(grep -c . <<<"$matches")"
        case "$count" in
            1) identity="$(awk '{print $2}' <<<"$matches")" ;;
            0) die "no valid 'Developer ID Application' identity in the keychain.
       A 'Developer ID Installer' certificate cannot sign apps. See docs/RELEASING.md, step 1." ;;
            *) echo "$matches" >&2
               die "several Developer ID Application identities; set RACCOONWRITER_SIGN_IDENTITY to one SHA-1 above" ;;
        esac
    elif ! grep -qF -- "$identity" <<<"$identities"; then
        die "RACCOONWRITER_SIGN_IDENTITY '$identity' is not a valid codesigning identity in the keychain"
    fi
    identity_name="$(grep -F -- "$identity" <<<"$identities" | head -1 | sed -E 's/^[^"]*"([^"]+)".*/\1/')"
    [[ "$identity_name" == "Developer ID Application: "* ]] \
        || die "'$identity_name' is not a Developer ID Application identity"
    echo "Identity: $identity_name"

    # Fail now, not after the build, if the notary credentials are missing or wrong.
    xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
        || die "notarytool cannot use keychain profile '$profile'. Create it with
       xcrun notarytool store-credentials $profile --apple-id <apple id> --team-id <team id>
       (docs/RELEASING.md, step 2), or set RACCOONWRITER_NOTARY_PROFILE."
    echo "Notary profile: $profile"
    sign_flags=(--timestamp --sign "$identity")
else
    identity="-"
    # An ad-hoc signature can't carry a secure timestamp.
    sign_flags=(--timestamp=none --sign -)
    echo "Identity: ad-hoc (--skip-notarize)"
fi

rm -rf "$out"
mkdir -p "$out"

# ---------------------------------------------------------------------------------------
step "Unit tests"
scripts/test.sh

step "Release build"
scripts/build.sh --release

# ---------------------------------------------------------------------------------------
step "Sign the app"
# No nested code in the bundle (ImageWriterCore is linked statically), so no --deep.
nested="$(find "$app/Contents" \( -name '*.framework' -o -name '*.dylib' -o -name '*.app' -o -name '*.xpc' -o -name '*.appex' \) -print)"
[[ -z "$nested" ]] || die "the app now has nested code, which this script does not sign:
$nested"
codesign --force --options runtime --entitlements "$entitlements" "${sign_flags[@]}" "$app"

step "Check the app's signature"
codesign --verify --strict --verbose=2 "$app"
details="$(codesign -dvv "$app" 2>&1)" || { echo "$details" >&2; die "codesign could not read the app's signature"; }
grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\(([^)]*,)?runtime[,)]' <<<"$details" \
    || { echo "$details" >&2; die "the app is not signed with the Hardened Runtime"; }
if (( notarize )); then
    grep -q '^Authority=Developer ID Application: ' <<<"$details" \
        || { echo "$details" >&2; die "the app's signature has no Developer ID Application authority"; }
    grep -q '^Timestamp=' <<<"$details" \
        || { echo "$details" >&2; die "the app's signature has no secure timestamp"; }
fi
ents="$(codesign -d --entitlements - --xml "$app" 2>/dev/null)" || die "codesign could not read the entitlements"
if grep -q 'get-task-allow' <<<"$ents"; then
    die "the app has the get-task-allow entitlement, which notarization rejects"
fi
plist="$app/Contents/Info.plist"
built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
[[ "$built_version" == "$version" ]] \
    || die "the built app says version $built_version, project.yml says $version"
grep -E '^(Authority|TeamIdentifier|Timestamp)=' <<<"$details" || true
echo "Version $built_version (build $build_number), Hardened Runtime on, no get-task-allow"

# ---------------------------------------------------------------------------------------
# Submits a file, waits for the result, saves notarytool's JSON and log in $out, and
# fails unless Apple accepted it. Sets notary_id.
notary_id=""
notarize_file() {
    local file="$1" label="$2"
    local result="$out/notary-$label.json" log="$out/notary-$label-log.json" status
    echo "Submitting $file (usually a few minutes)..."
    # notarytool's exit status isn't the whole story; the JSON status decides.
    xcrun notarytool submit "$file" --keychain-profile "$profile" --wait \
        --output-format json >"$result" || true
    notary_id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
    status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
    if [[ -n "$notary_id" ]]; then
        xcrun notarytool log "$notary_id" --keychain-profile "$profile" "$log" >/dev/null 2>&1 \
            || echo "warning: could not fetch the notarization log for $notary_id"
    fi
    if [[ "$status" != "Accepted" ]]; then
        cat "$result" >&2 || true
        [[ -f "$log" ]] && cat "$log" >&2
        die "notarization of $file ended with status '${status:-unknown}' (id ${notary_id:-none})"
    fi
    echo "Accepted: $notary_id"
}

app_notary_id="(skipped)"
dmg_notary_id="(skipped)"
if (( notarize )); then
    step "Notarize and staple the app"
    zip="$out/RaccoonWriter-$version-app.zip"
    ditto -c -k --keepParent "$app" "$zip"
    notarize_file "$zip" app
    app_notary_id="$notary_id"
    rm -f "$zip"
    # Stapling the app too means a first launch works offline once it's out of the DMG.
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
fi

# ---------------------------------------------------------------------------------------
step "Build the DMG"
staging="$out/dmg-staging"
mkdir -p "$staging"
# Shipped as "Raccoon Writer.app" so Finder shows the name with a space. The bundle
# folder name is not sealed by the signature or the notarization ticket.
ditto "$app" "$staging/$shipped_app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "Raccoon Writer" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
rm -rf "$staging"
codesign --force "${sign_flags[@]}" "$dmg"
codesign --verify --strict --verbose=2 "$dmg"

if (( notarize )); then
    step "Notarize and staple the DMG"
    notarize_file "$dmg" dmg
    dmg_notary_id="$notary_id"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
fi

# ---------------------------------------------------------------------------------------
step "Check the DMG's contents"
mount_point="$(mktemp -d -t raccoonwriter-dmg)"
detach() { hdiutil detach -quiet "$mount_point" >/dev/null 2>&1 || true; rmdir "$mount_point" 2>/dev/null || true; }
trap detach EXIT
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mount_point" "$dmg"
mounted_app="$mount_point/$shipped_app"
[[ -d "$mounted_app" ]] || die "the DMG has no $shipped_app"
[[ "$(readlink "$mount_point/Applications")" == /Applications ]] \
    || die "the DMG has no Applications link"
codesign --verify --strict "$mounted_app"
archs="$(lipo -archs "$mounted_app/Contents/MacOS/RaccoonWriter")"
for required in arm64 x86_64; do
    [[ " $archs " == *" $required "* ]] || die "the DMG's app is missing architecture $required"
done
scripts/check-release-flags.sh "$mounted_app"
if (( notarize )); then
    xcrun stapler validate "$mounted_app"
    for target in app dmg; do
        if [[ "$target" == app ]]; then
            assessment="$(spctl --assess --type execute -vv "$mounted_app" 2>&1)" || true
        else
            assessment="$(spctl --assess --type open --context context:primary-signature -vv "$dmg" 2>&1)" || true
        fi
        echo "$assessment"
        grep -q 'source=Notarized Developer ID' <<<"$assessment" \
            || die "Gatekeeper does not accept the $target as notarized"
    done
fi
detach
trap - EXIT
echo "DMG holds $shipped_app ($archs) and an Applications link"

# ---------------------------------------------------------------------------------------
step "Checksums and symbols"
(cd "$out" && shasum -a 256 "$dmg_name" >"$dmg_name.sha256")
ditto -c -k --keepParent "$dsym" "$out/RaccoonWriter-$version.dSYM.zip"
# scripts/publish-release.sh tags this commit, and checks it is still HEAD.
echo "$commit" >"$out/commit"
sha="$(awk '{print $1}' "$out/$dmg_name.sha256")"

echo
echo "Release $version (build $build_number) from commit ${commit:0:12}"
echo "  DMG:     $dmg"
echo "  SHA-256: $sha"
echo "  dSYM:    $out/RaccoonWriter-$version.dSYM.zip"
echo "  Notarization IDs: app $app_notary_id, DMG $dmg_notary_id"
if (( notarize )); then
    echo
    echo "Next: scripts/publish-release.sh $version"
else
    echo
    echo "*** NOT FOR DISTRIBUTION: ad-hoc signed and not notarized (--skip-notarize). ***"
fi
