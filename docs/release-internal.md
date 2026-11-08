# Internal releases

Run `make release-internal VERSION=0.1.0`. This creates a universal real-identity app in `dist/Ollie.app`, checks release hygiene, and creates `dist/release/Ollie-0.1.0.dmg` and `dist/release/appcast.xml`. It prints file sizes, DMG SHA-256, and architectures. It does not install, upload, or publish.

Supply exactly one signing input:

- `SPARKLE_ED_PRIVATE_KEY_FILE`: a path to a private file containing the base64 Ed25519 seed in Sparkle's exported-key format.
- `SPARKLE_ED_PRIVATE_KEY`: the same base64 seed supplied through a CI secret. The recipe removes it from child environments, writes a mode-0600 temporary file, passes that file to Sparkle's `sign_update --ed-key-file`, and deletes it on normal completion, exceptions, SIGTERM, SIGINT, and process exit.

The recipe never accesses Keychain. With neither input it builds through the DMG and fails with `No signing key`, leaving no appcast. Signing diagnostics are withheld to avoid logging malformed private inputs. The resulting signature must verify against the app's `SUPublicEDKey` before an appcast is written.

The production public key and feed are pinned by `scripts/release_policy.py` and checked against the real bundle. Production bundling ignores `SPARKLE_ED_PUBLIC_KEY`. Use the explicit `make release-throwaway VERSION=0.1.0` target (or the script's `--throwaway` option) for isolated signing tests. Only that path accepts a test public key for a release-shaped bundle; it uses `com.outlandish.ollie.throwaway.dev` and writes exclusively under `dist/throwaway-release/`. Its artifacts must never be distributed. The real `release-internal` target forces production mode even if a stray `THROWAWAY` environment variable is present. Both version fields are set from `VERSION`. Development plist settings are merged only into the development identity.

Use `make release-internal VERSION=0.1.1 CRITICAL=1 MIN_VERSION=0.1.0` to emit a critical-update tag and a minimum automatic-update version for that entry. Both options are optional; a minimum above VERSION is rejected. Release checks scan known secret values supplied through secret/token/password environment variables as well as credential patterns; diagnostics never echo the values.

The rollout publishes the two assets under the `creatorsamples_web` release tag `ollie-v<version>`. Each appcast enclosure uses `https://outlandishdigital.us/ollie/download/mac/<version>`. The feed URL is read from the single `SUFeedURL` setting in `Support/Info.plist`.

Normal updates check at launch and every six hours, download automatically, and install after the panel is closed and all Ollie windows have been unfocused for three minutes. Native confirmations, Companion dialogs, focused editors, unsent edited fields, and decision requests delay relaunch. An unsubmitted native confirmation follows decision content/version, not changing age labels. A visible Companion window reopens its exact same-origin URL (including query and fragment) without focus after installation. Any newer critical entry in the feed blocks the native panel with an Update required sheet while leaving Companion usable.

The rollout acceptance check remains a published `0.1.0` to `0.1.1` update received automatically by at least three people, observed through the `Ollie/<version>` user agent. Local builds and throwaway signatures do not establish that acceptance result. Sentry sends no reports while `OllieSentryDSN` is empty.

Checks: `swift test`, `python3 scripts/test-release.py`, `make check-dev`, and `make check-release`.
