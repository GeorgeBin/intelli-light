# Releasing

```sh
VERSION=$(tr -d '\r\n' < VERSION)
```

1. Update `CHANGELOG.md`: move changes under a new `## [x.y.z] - YYYY-MM-DD` section and add the release tag link (`[x.y.z]: https://github.com/KiwiGaze/codex-status-bar/releases/tag/vx.y.z`), matching CHANGELOG's existing style.
2. Update the root `VERSION` file. `scripts/check-metadata.sh` verifies all generated mirrors.
3. Build the signed, notarized, universal DMG:
   ```bash
   export TEAM_ID=<your Developer ID team id>
   NOTARY_PROFILE=intelli-light ./apps/macos/package.sh
   ```
4. Validate the artifact:
   ```bash
   xcrun stapler validate apps/macos/dist/IntelliLight-${VERSION}.dmg
   spctl -a -t open --context context:primary-signature apps/macos/dist/IntelliLight-${VERSION}.dmg
   lipo -info "apps/macos/build/Intelli Light.app/Contents/MacOS/IntelliLight"   # x86_64 arm64
   ```
5. Tag and publish (asset MUST be named `IntelliLight-${VERSION}.dmg`):
   ```bash
   git tag vx.y.z && git push origin vx.y.z
   gh release create vx.y.z "apps/macos/dist/IntelliLight-${VERSION}.dmg" --title vx.y.z --notes-from-tag
   ```
