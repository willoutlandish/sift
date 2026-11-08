# Internal releases

Run `make release-internal VERSION=0.1.0`. This creates a universal real-identity app in `dist/Ollie.app`, checks release hygiene, and creates `dist/release/Ollie-0.1.0.dmg` and `dist/release/appcast.xml`. It prints file sizes, DMG SHA-256, and architectures. It does not install, upload, or publish.

Supply exactly one signing input:

- `SPARKLE_ED_PRIVATE_KEY_FILE`: a path to a private file containing the base64 Ed25519 seed in Sparkle's exported-key format.
- `SPARKLE_ED_PRIVATE_KEY`: the same base64 seed supplied through a CI secret. The recipe removes it from child environments, writes a mode-0600 temporary file, passes that file to Sparkle's `sign_update --ed-key-file`, and deletes it in `finally`.

The recipe never accesses Keychain. With neither input it builds through the DMG and fails with `No signing key`, leaving no appcast. Signing diagnostics are withheld to avoid logging malformed private inputs. The resulting signature must verify against the app's `SUPublicEDKey` before an appcast is written.

The production public key lives in `Support/Info.plist`. `SPARKLE_ED_PUBLIC_KEY` can override it at bundle creation for isolated throwaway-key verification; never distribute those test artifacts. Both version fields are set from `VERSION`. Development plist settings are merged only into the development identity.

The rollout publishes the two assets under the `creatorsamples_web` release tag `ollie-v<version>`. Each appcast enclosure uses `https://outlandishdigital.us/ollie/download/mac/<version>`. The feed URL is read from the single `SUFeedURL` setting in `Support/Info.plist`.

Normal updates check at launch and every six hours, download automatically, and install after the panel is closed and all Ollie windows have been unfocused for three minutes. Native confirmations, Companion dialogs, and decision requests delay relaunch. A visible Companion window is reopened without focus after installation. Critical releases also block the native panel with an Update required sheet while leaving Companion usable.

The rollout acceptance check remains a published `0.1.0` to `0.1.1` update received automatically by at least three people, observed through the `Ollie/<version>` user agent. Local builds and throwaway signatures do not establish that acceptance result. Sentry sends no reports while `OllieSentryDSN` is empty.

Checks: `swift test`, `python3 scripts/test-release.py`, `make check-dev`, and `make check-release`.
