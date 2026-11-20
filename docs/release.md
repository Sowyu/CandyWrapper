# Releases

CandyWrapper ships as GitHub releases of https://github.com/Sowyu/CandyWrapper. Nothing else is an update source.

## Signing on the build Mac

Set up on 2026-10-11 for Milestone 9. The secrets live only in keychains on the build Mac and never enter the repo, logs or command lines.

- `~/Library/Keychains/candywrapper-release.keychain-db` is a keychain only for releases. It is not in the user's keychain search list, so pass it to tools with `--keychain` or by path. It has no auto-lock timeout but locks at reboot.
- Its password is the login keychain item with service `dev.candywrapper.release-keychain` (account `release`). Only `/usr/bin/security` may read it without a prompt.
- Any process running as this user can therefore read that password and the signing key; the M9 review rated this high. Such a process also has the git token that publishes releases, so the key adds little on its own. The keychain stays locked outside releases: it auto-locks after 5 idle minutes and on sleep, and `scripts/release` locks it on exit. Making each release wait for the user's click on a macOS prompt is the stronger option, left to the user.
- Since v0.1.7 the code signing identity is the user's Apple Development certificate (free personal team, Team ID `8Q677AYRU7`, created in Xcode on 2026-10-12 on the first build Mac, and again on 2026-11-21 on the Mac mini M2 Pro after that Mac was returned, valid until 2027-11-20) in the login keychain. Signing in to Xcode with the same Apple ID on a new Mac makes a new certificate with the same Team ID, so this certificate needs no backup; `scripts/release` signs with `Apple Development` and checks the Team ID. Its key allows `codesign` without a prompt (the user chose Always Allow once). It needs Apple's WWDR G3 intermediate, which is now in the login keychain. Why a Team ID: for an app without one, macOS stamps login keychain items with the build's cdhash as their partition ID, so every update asked for the keychain password again (reproduced 2026-10-12); with a Team ID the partition is `teamid:8Q677AYRU7` and stays the same across updates. Library validation is back on: Sparkle and the app share the team. Renew the certificate in Xcode before October 2027; the designated requirement names the developer certificate, which keeps its name across renewals.
- The earlier self-signed `CandyWrapper Release` identity (v0.1.3 to v0.1.6) stays in the release keychain, unused for signing.
- The Sparkle EdDSA private key is the item with service `dev.candywrapper.sparkle-ed25519` in the release keychain: base64 of a 32-byte Ed25519 seed, Sparkle's current key format. The public key for `SUPublicEDKey` is `uEahF8lFv2jlwRpuV6iYH7ExKGN6uDNatub9V3IyxtE=`, made on 2026-11-21 on the Mac mini M2 Pro after the first build Mac was returned with the only copy of the earlier key (`3lPqUDTLuxLA+rq4R0InFIoN6hun/6vy1ElXcGaTnqA=`, v0.1.3 to v1.14.14). Installs up to v1.14.14 trust only the earlier key, so they need one manual install of a later version.
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
3. Before signing, it runs `scripts/build-helper <version> <out>/helper --sign` from the same worktree: the CandyWrapper Helper's universal macOS binary, signed with the same identity, and its static Linux x86_64 and arm64 binaries, each as `candywrapper-helper-<version>-<platform>.tar.gz` with `SHA256SUMS`. It writes their sums into the app as `Contents/Resources/helper-manifest.json`, which the Connectors tab downloads the helper from (docs/connectors.md). The Linux builds need swift.org's toolchain and its Static Linux SDK, which Xcode's toolchain can't replace: `~/CandyWrapper-research/tools/swift-6.4.1.xctoolchain` with `swift-6.4.1-RELEASE_static-linux-0.1.0` installed, or `SWIFT_LINUX_TOOLCHAIN` pointing at another one.
4. It writes `CandyWrapper-<version>-arm64.zip` (ditto, symlinks kept) and a DMG, signs the zip with `sign_update` (seed on stdin), adds the item to the published appcast with earlier items kept, and signs the appcast. A build number already in the appcast stops it.
5. Without `--dry-run` it creates the GitHub release `v<version>` (a pre-release on the nightly channel), uploads zip, DMG, the helper's tarballs and `SHA256SUMS`, and checks their downloads. A rerun after a failed publish finds the existing release and replaces its assets with the new build.
6. The new feed goes up as `appcast-next.xml` on the `appcast` release, then takes the old feed's place by rename, so a failed upload leaves the old feed serving; the script then checks that the feed URL serves the new file. The published feed's items carry over only when its signature verifies (`scripts/appcast-key-check`, which runs `sign_update --verify`); a feed changed outside the script stops the release. `--previous-key` is for the one release after a key change, below.

Raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in project.yml first: Sparkle compares the build number. The notes file is both the release body and the appcast description, which the app's release notes popover reads. `--previous-key` is not a test option: it works with and without `--dry-run`, and test options still need `--dry-run` when it is given. `scripts/appcast-key-check-test` checks the appcast step and prints `ok`. The test options (`--source`, `--bundle-id`, `--version`, `--build`, `--feed-url`, `--public-key`, `--ed-key-file`, `--download-prefix`, `--appcast`) work only with `--dry-run`.

## Key rotation, 2026-11-21

The first build Mac went back to its rental company with the only copy of the EdDSA seed that signed v0.1.3 to v1.14.14, public key `3lPqUDTLuxLA+rq4R0InFIoN6hun/6vy1ElXcGaTnqA=`. Nobody has tried to recover it. Since 2026-11-21 the key is `uEahF8lFv2jlwRpuV6iYH7ExKGN6uDNatub9V3IyxtE=`, made on the Mac mini M2 Pro.

### What 1.14.14 and older do

v1.14.14 ships Sparkle 2.10.0 with `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` on, no `SUSignedFeedFailureExpirationInterval`, and only the old key in `SUPublicEDKey`. The feed check is SUAppcastDriver.m:94-171 in Sparkle 2.10.0, and the archive check is AppInstaller.m:270-292 with SUUpdateValidator.m:60-113. Every release since v0.1.3 has Sparkle 2.10.0 and the same two settings.

1. For 20 days after its first failed check, an old install rejects the new feed on every check. Sparkle stores the date of that first failure in the app's defaults as `SUInitialFailedFeedSigningValidationDate`. The hourly background checks fail without showing anything, so the sidebar stays as it was. Check for Updates... shows the alert "Could not check for updates." with Sparkle's text "The update feed is improperly signed and could not be validated. Please try again later or contact the app developer."
2. After those 20 days Sparkle reads the unverified feed anyway, minus descriptions, release notes links, critical flags and informational items (`DEFAULT_APPCAST_FAILURE_EXPIRATION_INTERVAL`, SUAppcastDriver.m:39). It offers 1.15.0 and the sidebar pill shows it. Download fetches the ZIP, and the installer rejects it before extraction because the old key doesn't match its signature. The app then shows "The update is improperly signed and could not be validated. Please try again later or contact the app developer." and the pill reads "Download failed for 1.15.0. Click to retry." Each retry downloads the ZIP again and fails the same way.
3. A feed the old key signed whose newest ZIP the new key signed fails as in step 2 from the first check. We can't make that feed anyway.

Nothing installs, and nothing retries on its own beyond Sparkle's hourly check, since `SUAutomaticallyUpdate` and `SUAllowsAutomaticUpdates` are off. Nothing crashed in the runs below. Only a feed that verifies clears the stored date, so an old install stays like this until someone installs 1.15.0 by hand, as the README says under "If you have 1.14.14 or older".

I checked this on 2026-11-21 by reading Sparkle 2.10.0's source and then running it. The v1.14.14 ZIP came from `gh release download`. Two copies got test bundle ids, `dev.candywrapper.rotation-test` and `-test2`, and were signed again by the same team. A command-line harness drove Sparkle 2.10.0's `SPUUpdater` for each copy with a user driver that only logs, against feeds on 127.0.0.1 signed with throwaway keys. It used the Swift package's copy of Sparkle 2.10.0, because dyld refused to load the app's thinned copy into an unsigned tool. No window opened, and the real `dev.candywrapper.app` defaults and caches were not touched. The results:

- A user check of a feed signed by another key ended in error 1000, "The update feed is improperly signed...", with 3002 "EdDSA signature does not match" under it.
- A background check of the same feed ended in the same error, and Sparkle passed nothing to the user driver.
- With the stored failure date set 22 days back, a user check found 1.15.0 (82), downloaded it and ended in error 4005, "The update is improperly signed...", over "(Ed)DSA signature validation before unarchiving failed".
- A feed signed with the host's own test key, with its ZIP signed by another key, ended in the same 4005 error. A background check of it offered 1.15.0.

What the user sees comes from v1.14.14's UpdateController.swift and UpdateUI.swift, which are unchanged on `catchup-4928`.

### Rotation without the old key

Sparkle 2.10.0 has no supported way to rotate the key for this setup. Its one rotation path accepts an update whose EdDSA signature fails when the update's Apple code signature vouches for it instead. With `SUVerifyUpdateBeforeExtraction` on, as in every CandyWrapper release, that check runs on the downloaded archive before extraction. It requires a Developer ID Application certificate with the old app's Team ID (SUCodeSigningVerifier.m:323-363, `certificate leaf[field.1.2.840.113635.100.6.1.13]`). CandyWrapper is signed with an Apple Development certificate and isn't notarized, and a ZIP carries no code signature at all. The more lenient check after extraction in SUUpdateValidator.m:304-410, which accepts any matching code signature, never runs when `SUVerifyUpdateBeforeExtraction` is on.

The harness shows the same thing. In the reduced mode from step 2, a DMG enclosure signed with this Apple Development certificate failed with "The Apple code signature of new downloaded archive is either not Developer ID code signed, or doesn't have a Team ID that matches the old app version (8Q677AYRU7)".

### The feed

I kept the feed URL and the old items, with the whole feed signed by the new key. This is what `scripts/release` already writes, so publishing needs only `--previous-key`. 1.15.0 and later verify the feed and the ZIP with the new key and update normally. 1.14.14 and older fail closed as described above: they never install anything the new key signed, and the error is Sparkle's own text.

These were the other options:

- Starting the feed fresh at the same URL changes nothing for old installs. 1.15.0 lists only items newer than itself, so dropping old items changes nothing it shows either, and it would need a script change.
- A new feed URL for 1.15.0 and later, with the old URL left alone, leaves old installs on a feed that still verifies. 1.14.14 would then report "CandyWrapper 1.14.14 is currently the newest version available." forever, and there would be two feeds to keep.
- Marking every new item as an informational update below build 82 would make Sparkle drop it for old installs after the 20 days, so they would keep showing the feed error. It would also hide 1.15.0 from them completely, and every later item would need the marker.

### Publishing 1.15.0

Raise the version to 1.15.0 (82) in project.yml first, then run this once:

```sh
scripts/release --previous-key 3lPqUDTLuxLA+rq4R0InFIoN6hun/6vy1ElXcGaTnqA= --notes notes.md <commit>
```

`--previous-key` makes `scripts/appcast-key-check` accept a published feed that verifies with that public key, checked with CryptoKit since `sign_update --verify` needs the private key. A feed that verifies with neither key still stops the release. So does a feed that already verifies with the new key, so the option fails if it's left in a later release. Without it the script behaves as before.

The dry run on 2026-11-21 ran `scripts/release --dry-run --version 1.15.0 --build 82 --previous-key 3lPqUDTLuxLA+rq4R0InFIoN6hun/6vy1ElXcGaTnqA= 847c7db4`. It printed "the published appcast is signed by the previous key" and "appcast: 79 item(s)", and it ended with "dry run: nothing published". Verified from its output: codesign strict on the ZIP and DMG apps, Team ID 8Q677AYRU7 on both apps and the DMG, 1.15.0 (82), `SUPublicEDKey` the new key, the DMG and ZIP checksums in sha256.txt, the helper tarballs against SHA256SUMS and the app's helper manifest, all 78 earlier items carried over unchanged, and the top item 1.15.0 (82) with the ZIP's 21,121,674 bytes. The new appcast and the ZIP's signature verify with the new key in `sign_update --verify` and in CryptoKit against `uEahF8lFv2jlwRpuV6iYH7ExKGN6uDNatub9V3IyxtE=`. The new appcast does not verify against the old key.

## Manual release, v0.1.0 to v0.1.2

The Log in PROGRESS.md describes it: a Release build from a clean worktree of the commit, `strip -x -S`, ad-hoc signing with the hardened runtime, a copy with a test bundle id checked in `--snapshot` mode, `ditto -c -k --sequesterRsrc --keepParent`, SHA-256 in the notes, an annotated tag, and the GitHub REST API through `git credential fill` (no `gh` here) to create the release and upload the zip. `/tmp/cw-release3/publish.py` was the v0.1.2 publisher. Milestone 9 replaces this with `scripts/release`.
