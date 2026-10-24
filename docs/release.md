# Releases

CandyWrapper ships as GitHub releases of https://github.com/Sowyu/CandyWrapper. Nothing else is an update source.

## Signing on the build Mac

Set up on 2026-10-11 for Milestone 9. The secrets live only in keychains on the build Mac and never enter the repo, logs or command lines.

- `~/Library/Keychains/candywrapper-release.keychain-db` is a keychain only for releases. It is not in the user's keychain search list, so pass it to tools with `--keychain` or by path. It has no auto-lock timeout but locks at reboot.
- Its password is the login keychain item with service `dev.candywrapper.release-keychain` (account `release`). Only `/usr/bin/security` may read it without a prompt.
- Any process running as this user can therefore read that password and the signing key; the M9 review rated this high. Such a process also has the git token that publishes releases, so the key adds little on its own. The keychain stays locked outside releases: it auto-locks after 5 idle minutes and on sleep, and `scripts/release` locks it on exit. Making each release wait for the user's click on a macOS prompt is the stronger option, left to the user.
- Since v0.1.7 the code signing identity is the user's Apple Development certificate (free personal team, Team ID `8Q677AYRU7`, created in Xcode on 2026-10-12, valid until 2027-10-12) in the login keychain; `scripts/release` signs with `Apple Development` and checks the Team ID. Its key allows `codesign` without a prompt (the user chose Always Allow once). It needs Apple's WWDR G3 intermediate, which is now in the login keychain. Why a Team ID: for an app without one, macOS stamps login keychain items with the build's cdhash as their partition ID, so every update asked for the keychain password again (reproduced 2026-10-12); with a Team ID the partition is `teamid:8Q677AYRU7` and stays the same across updates. Library validation is back on: Sparkle and the app share the team. Renew the certificate in Xcode before October 2027; the designated requirement names the developer certificate, which keeps its name across renewals.
- The earlier self-signed `CandyWrapper Release` identity (v0.1.3 to v0.1.6) stays in the release keychain, unused for signing.
- The Sparkle EdDSA private key is the item with service `dev.candywrapper.sparkle-ed25519` in the release keychain: base64 of a 32-byte Ed25519 seed, Sparkle's current key format. The public key for `SUPublicEDKey` is `3lPqUDTLuxLA+rq4R0InFIoN6hun/6vy1ElXcGaTnqA=`.
- The identity's PKCS#12 export, its public certificate and the public EdDSA key are in `~/CandyWrapper-research/backups/release-signing/`, outside the repo. The PKCS#12 password is the item `dev.candywrapper.release-p12` in the release keychain.

Unlock the release keychain before any other use. A query against a locked keychain opens a password dialog on the GUI screen and the command waits for it.

```sh
KC=$HOME/Library/Keychains/candywrapper-release.keychain-db
PW=$(security find-generic-password -s dev.candywrapper.release-keychain -w)
print -r -- "unlock-keychain -p $PW $KC" | security -i   # the password goes through stdin, not argv
unset PW
codesign --force --sign "Apple Development" --options runtime <path>   # login keychain, Team ID 8Q677AYRU7
security find-generic-password -s dev.candywrapper.sparkle-ed25519 -w "$KC" | sign_update --ed-key-file - <archive>
```

`sign_update` and `generate_appcast` come from Sparkle 2.10.0's `Sparkle-for-Swift-Package-Manager.zip` (SHA-256 `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`, matching the digest GitHub publishes for the release asset).

Losing the EdDSA key can strand every installed copy until its owner reinstalls by hand. The backup folder sits on the same Mac and holds the identity but not the EdDSA seed, so it protects against a damaged keychain at best. An off-machine backup of both is still an open question for the user.

## scripts/release

Since Milestone 9 one command makes a release from a commit: `scripts/release --notes notes.md [--channel nightly] [--dry-run] <commit>`.

1. It unlocks the release keychain, then builds Release (arm64) in a clean worktree of the commit.
2. It strips the executable, thins Sparkle to arm64 and signs inside-out with the Apple Development identity: Autoupdate, Updater.app, the framework, then the app, and checks the Team ID. Library validation stays on: the framework and the app share the Team ID.
3. Before signing, it runs `scripts/build-helper <version> <out>/helper --sign` from the same worktree: the CandyWrapper Helper's universal macOS binary, signed with the same identity, and its static Linux x86_64 and arm64 binaries, each as `candywrapper-helper-<version>-<platform>.tar.gz` with `SHA256SUMS`. It writes their sums into the app as `Contents/Resources/helper-manifest.json`, which the Helper button installs from (docs/orchestrator-helper.md). The Linux builds need swift.org's toolchain and its Static Linux SDK, which Xcode's toolchain can't replace: `~/CandyWrapper-research/tools/swift-6.4.1.xctoolchain` with `swift-6.4.1-RELEASE_static-linux-0.1.0` installed, or `SWIFT_LINUX_TOOLCHAIN` pointing at another one.
4. It writes `CandyWrapper-<version>-arm64.zip` (ditto, symlinks kept) and a DMG, signs the zip with `sign_update` (seed on stdin), adds the item to the published appcast with earlier items kept, and signs the appcast. A build number already in the appcast stops it.
5. Without `--dry-run` it creates the GitHub release `v<version>` (a pre-release on the nightly channel), uploads zip, DMG, the helper's tarballs and `SHA256SUMS`, and checks their downloads. A rerun after a failed publish finds the existing release and replaces its assets with the new build.
6. The new feed goes up as `appcast-next.xml` on the `appcast` release, then takes the old feed's place by rename, so a failed upload leaves the old feed serving; the script then checks that the feed URL serves the new file. The published feed's items carry over only when its signature verifies (`sign_update --verify`); a feed changed outside the script stops the release.

Raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in project.yml first: Sparkle compares the build number. The notes file is both the release body and the appcast description, which the app's release notes popover reads. The test options (`--source`, `--bundle-id`, `--version`, `--build`, `--feed-url`, `--public-key`, `--ed-key-file`, `--download-prefix`, `--appcast`) work only with `--dry-run`.

## Manual release, v0.1.0 to v0.1.2

The Log in PROGRESS.md describes it: a Release build from a clean worktree of the commit, `strip -x -S`, ad-hoc signing with the hardened runtime, a copy with a test bundle id checked in `--snapshot` mode, `ditto -c -k --sequesterRsrc --keepParent`, SHA-256 in the notes, an annotated tag, and the GitHub REST API through `git credential fill` (no `gh` here) to create the release and upload the zip. `/tmp/cw-release3/publish.py` was the v0.1.2 publisher. Milestone 9 replaces this with `scripts/release`.
