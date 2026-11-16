# Publishing an app update

InputTranslator reads its signed Sparkle appcast from the latest stable GitHub Release. Each release that should be installable in the app needs an `appcast.xml` asset alongside the exact ZIP used to generate it.

1. Increase both `MARKETING_VERSION` and the integer `CURRENT_PROJECT_VERSION`. Sparkle compares build numbers to decide whether an update is newer.
2. Archive the universal app, sign it with Developer ID, notarize it, and staple the ticket to the app. Package it as `InputTranslator-v<version>-macOS-universal.zip` with `InputTranslator.app` at the root.
3. Generate and verify the appcast on the Mac that has the `InputTranslatorUpdates` signing key in Keychain. Use the Sparkle tools from the version pinned in the Xcode project.

   ```sh
   python3 scripts/create-appcast.py /path/to/Sparkle/bin /path/to/InputTranslator-v1.2.3-macOS-universal.zip
   ```

4. Attach both the ZIP and the generated `appcast.xml` to the same GitHub release before publishing it as latest. Use the Git tag that matches the version in the filename. Rerun the script if you change the ZIP.
5. Download the published assets, verify the ZIP hash against the release artifact, and confirm that an older updater-enabled build can check and install the update. Keep a secure backup of the Sparkle private key used for signing releases.

[Download feed](https://github.com/akz142857/InputTranslator/releases/latest/download/appcast.xml) · [Sparkle release signing](https://sparkle-project.org/documentation/publishing/)
