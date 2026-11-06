# Releasing Murmur

Murmur uses Sparkle 2 and the `murmur-releases` R2 bucket. The public feed is https://updates.murmur.bonusobjective.com/appcast.xml.

## Release checklist

1. **Bump the version.** Set `CFBundleShortVersionString` and increment the numeric `CFBundleVersion` in `project/Info.plist`. Build numbers must increase, even across marketing versions.
2. **Run the tests.** `swift test`. Optionally `MURMUR_LIVE=1 swift test --filter TidyLiveTests` if clean-up models changed.
3. **Build and notarize.** `Packaging/release.sh`. It archives, signs, notarizes, staples, zips and writes a signed appcast under `build/releases/<version>-<build>/feed`. Nothing is uploaded yet.
4. **Inspect the feed.** Check `feed/appcast.xml` has the new `<sparkle:version>`, the right download URL and a signature, and that the zip opens to a signed, stapled `Murmur.app` (`codesign --verify --deep --strict` and `spctl -a -vv`).
5. **Test the update.** On a clean Mac with the previous version installed, point it at the new feed and let Sparkle update. Confirm the app relaunches, keeps its permissions, and dictates.
6. **Publish.** `Packaging/release.sh --publish` uploads the versioned archive, then `Murmur-latest.zip`, then the feed. The script refuses to overwrite an existing archive.

## Signing and credentials

The `murmur` Sparkle signing key is stored in the macOS login Keychain. Back it up securely outside this machine: use `generate_keys --account murmur -x <secure-path>` from `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin`, then move the file to an encrypted backup and remove the local export. Never commit or share it. Losing this key can prevent existing users from updating.

The Developer ID Application identity for team DQG6RVCCWV and a `notarytool` Keychain profile named `murmur` are required. Configure the profile using `xcrun notarytool store-credentials murmur`; enter credentials in its prompts. Wrangler must be logged in to the Cloudflare account containing the bucket.

`Packaging/release.sh` reads `DEVELOPMENT_TEAM`, `DEVELOPER_ID`, `NOTARY_PROFILE`, `R2_BUCKET` and `RELEASE_BASE_URL` from the environment and defaults to the official values, so a fork can release its own build without editing the script.

## Caching

The feed and `Murmur-latest.zip` are uploaded with `no-cache, max-age=0, must-revalidate`; versioned archives are uploaded `immutable` with a one-year lifetime. Cloudflare's default Browser Cache TTL (four hours) overrides those origin headers for `.zip` responses, so the website's download link can serve a stale build for hours after a release. Fix it in one of two ways:

- **Point the download at the versioned URL.** The release script prints it (`Versioned archive: https://updates.murmur.bonusobjective.com/Murmur-<version>-<build>.zip`). Serving that from the website is safe to cache forever and is the simplest fix; `Murmur-latest.zip` then only exists for links that cannot be updated.
- **Or make Cloudflare respect the origin.** In the Cloudflare dashboard for the zone, set Caching → Configuration → Browser Cache TTL to *Respect Existing Headers*, or add a Cache Rule matching `http.request.uri.path eq "/Murmur-latest.zip"` with Edge TTL and Browser TTL both set to *Respect origin cache-control*. Purge that URL after publishing if a stale copy is already cached.

## Notes

Each run retains its output under `build/releases/`. Keep historical archives available: existing feed entries may refer to them. Do not publish two releases concurrently. For subsequent releases, the script retrieves and preserves the current feed; it deliberately does not create delta updates.
