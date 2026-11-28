# Updates for the Mac download (Sparkle)

The direct-download Mac app updates itself with
[Sparkle](https://sparkle-project.org) (MIT). App Store builds (iOS now, the
Mac App Store build later) update through the store and contain no Sparkle
code. Spec: "Decisions made", Updates.

## How it works

- `PlatenReader/Sources/Updates.swift` starts Sparkle's standard updater at
  launch, in Release builds only, and never in automated runs
  (`PLATEN_TEST_HOME`). It adds **Platen Reader › Check for Updates…** and,
  in **Settings › Advanced**, *Check for updates automatically* (on by
  default) with a *Check Now* button.
- About once a day it reads the **appcast** at
  `https://shahidhussain.com/projects/platen-reader/appcast.xml`
  (`SUFeedURL` in `PlatenReader/Info.plist`). That address is permanent:
  every copy ever shipped looks there, so it must never move.
- The appcast names the latest version and its disk image on GitHub
  releases. Sparkle downloads it, checks its EdDSA signature against
  `SUPublicEDKey` (Info.plist), and offers to install and restart.
- Nothing about the Mac is sent (`SUEnableSystemProfiling` is off). The check
  is the agreed network exception (CLAUDE.md).
- Version numbers: Sparkle compares `CFBundleVersion`, which the release
  workflow sets to its run number, so each release is higher than the last.

It is all in place since 28 Nov 2026 (version 1.0.13). The first release
after that is the first that can be updated from; copies before it have no
updater.

## Setting up (once)

1. **Add the package** (done 28 Nov 2026: Sparkle 2.10.1, Mac target only).
   In Xcode: File › Add Package Dependencies…,
   `https://github.com/sparkle-project/Sparkle`, *Up to Next Major Version*
   from 2.6.0, the **Sparkle** library on the **PlatenReader** (Mac) target
   only. The release workflow signs Sparkle's helpers again with the
   Developer ID before notarising (as Sparkle asks of builds made outside
   Xcode's Archive).
2. **Make the signing keys** (done 28 Nov 2026; the public key is in
   Info.plist). Sparkle's tool comes with the package:

   ```sh
   GENKEYS=$(find ~/Library/Developer/Xcode/DerivedData build/DerivedData -path '*artifacts/sparkle/Sparkle/bin/generate_keys' 2>/dev/null | head -1)
   "$GENKEYS"
   ```

   It keeps the private key in your login keychain and prints the
   **public** key. The public key is not secret: it goes into Info.plist
   (`SUPublicEDKey`).
3. **Back up the private key** and give it to the release workflow (done
   28 Nov 2026: the secret is set, and a copy is in the password manager):

   ```sh
   "$GENKEYS" -x sparkle_private.key
   gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle_private.key
   ```

   Keep a copy somewhere safe (a password manager), then delete the file.
   If the private key is lost, no copy already installed can ever be
   updated again.

## Each release

1. Push a version tag (README, "Releasing"). The workflow builds, notarises
   and staples the app and the disk image, signs the image for Sparkle, and
   attaches `appcast.xml` to the GitHub release.
2. Download that `appcast.xml` and upload it to
   `shahidhussain.com/projects/platen-reader/appcast.xml`, replacing the
   old one. Until it is uploaded, nobody is offered the new version.

A tag with a suffix (`v1.0.11-rc1`) makes a pre-release with no appcast, so
testing the download never offers an update to anyone.
