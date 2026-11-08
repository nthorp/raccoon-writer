# Releasing Raccoon Writer

A release is a Developer ID signed, notarized and stapled DMG on GitHub Releases, linked from raccoonwriter.com. Two scripts do the work, run on a Mac by hand (there is no CI release):

- `scripts/release.sh` tests, builds Release, signs, notarizes and staples the app, builds the DMG, then signs, notarizes and staples the DMG. Output goes to `build/release/`.
- `scripts/publish-release.sh <version>` tags the commit, pushes the tag, and creates a **draft** GitHub release with the DMG, its `.sha256` and the zipped dSYM.

Neither script touches a disk: `hdiutil` only creates and mounts an image file. `scripts/release.sh --skip-notarize` runs the same steps with an ad-hoc signature and no Apple credentials, into `build/release-adhoc/`. Use it to test the pipeline. Its DMG is not for distribution.

## One-time setup

1. **Developer ID Application certificate.** In Xcode: Settings › Accounts › the Northwoods Digital LLC team › Manage Certificates › **+** › **Developer ID Application**. Only the team's Account Holder can create one. Xcode puts the certificate and its private key in the login keychain and installs Apple's Developer ID intermediate certificate. Check it:

   ```sh
   security find-identity -v -p codesigning
   # 1) <SHA-1> "Developer ID Application: Northwoods Digital LLC (VGLYJ29DX8)"
   ```

   A *Developer ID Installer* certificate is a different one: it signs `.pkg` installers and can't sign an app. Export the Application certificate with its key (Keychain Access › right-click › Export, `.p12`) and keep the file somewhere safe. Without the key you can't sign updates, only create a new certificate.

2. **Notary credentials.** Create an app-specific password at [account.apple.com](https://account.apple.com) (Sign-In and Security › App-Specific Passwords), then store it in the keychain:

   ```sh
   xcrun notarytool store-credentials raccoon-writer-notary \
       --apple-id <your Apple ID> --team-id VGLYJ29DX8
   ```

   It asks for the app-specific password. To use another profile name, set `RACCOONWRITER_NOTARY_PROFILE`.

3. **GitHub CLI.** `gh auth status` shows you logged in to an account that can push to `nthorp/raccoon-writer`.

## Each release

1. **Version.** In `project.yml`, set `MARKETING_VERSION` (for example `1.1.0`) and raise `CURRENT_PROJECT_VERSION` by one.
2. **Release notes.** Write `docs/release-notes/v<version>.md`. It becomes the GitHub release description, so write it for people downloading the app.
3. **Commit and push** to `main`. Both scripts refuse a dirty tree, and the publish script refuses a commit that isn't on `origin/main`.
4. **Build:** `scripts/release.sh`. It takes a few minutes per notarization round, and there are two (app, then DMG). It stops at the first problem. On success it prints the DMG path, its SHA-256 and both notarization IDs, and the app and the DMG have each passed `spctl` as `source=Notarized Developer ID`.
5. **Draft release:** `scripts/publish-release.sh <version>`. It checks the DMG again, checks that the DMG was built from `HEAD`, then tags `v<version>`, pushes the tag and creates the draft.
6. **Check the download.** On the draft release page, download the DMG **in Safari**, so it gets the quarantine flag like a user's download. Then:
   - `shasum -a 256 ~/Downloads/RaccoonWriter.dmg` matches the `.sha256` file.
   - Open the DMG and drag Raccoon Writer to Applications. Launch it from Applications. The only prompt is macOS's "downloaded from the Internet" one, with no "cannot be verified" or "damaged" warning.
   - Raccoon Writer › About shows the new version.
   - Write and verify one image to a USB stick whose contents you don't need (as in `docs/HARDWARE_TESTS.md`).
7. **Publish** the draft on GitHub.
8. **Website.** raccoonwriter.com's Download button points at `https://github.com/nthorp/raccoon-writer/releases/latest/download/RaccoonWriter.dmg`, so it needs no change per release. Update any version number shown on the site.

The DMG is always named `RaccoonWriter.dmg`, with the version only in the release title and the dSYM name. That fixed name is what makes the `releases/latest/download/` link work, so don't rename it. GitHub serves `latest` from the newest published release that isn't a draft or a prerelease.

## Troubleshooting

- **"no valid 'Developer ID Application' identity".** Do setup step 1. If `security find-identity -p codesigning` (without `-v`) lists the identity but `-v` doesn't, Apple's intermediate certificate is usually missing: download [`DeveloperIDG2CA.cer`](https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer) and run `security add-certificates -k ~/Library/Keychains/login.keychain-db DeveloperIDG2CA.cer`. If the identity isn't listed at all, its private key isn't on this Mac (import the `.p12`), or it has expired or been revoked.
- **"several Developer ID Application identities".** Usually an old and a renewed certificate. Set `RACCOONWRITER_SIGN_IDENTITY` to the SHA-1 of the one to use.
- **"notarytool cannot use keychain profile".** Do setup step 2. An app-specific password stops working if you change your Apple ID password.
- **Notarization status `Invalid`.** The script prints Apple's log, also saved as `build/release/notary-app-log.json` or `notary-dmg-log.json`. Typical causes are a missing Hardened Runtime, a missing secure timestamp or the `get-task-allow` entitlement, and the script checks all three before submitting.
- **"tag v<version> already exists".** That version was released, or a failed publish pushed the tag. Bump the version. Delete a tag only if no release was published from it.
- **Starting over after a failed run.** `build/release/` is rebuilt from scratch on every run. Nothing is uploaded until `publish-release.sh`.
