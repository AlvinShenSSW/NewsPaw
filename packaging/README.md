# NewsPaw macOS package

Build on a Mac with Swift, uv and the managed CPython 3.13.7 distribution for that Mac's architecture. The target Mac uses the Python and dependencies inside the app.

```sh
uv python install 3.13.7
mkdir -p /tmp/newspaw-package
./packaging/build-macos.sh /tmp/newspaw-package/NewsPaw.app
```

For audio processing, pass `--ffmpeg /absolute/ffmpeg /absolute/license` with a redistributable executable for the same architecture. Its dependencies must resolve inside the app or to system libraries. The build records its checksum and license. When the repository contains the Apple Vision helper source, the build also places the helper next to the embedded interpreter.

The local build is for development inspection. For distribution, sign embedded executables and libraries and then the app with the appropriate Developer ID and hardened runtime. Submit the signed package with Apple's notary tooling and staple the result before claiming notarization. [Apple notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Login and upgrades

Use Delivery & Service to register the per-user login item and review its actual system approval. Settings and the worker are separate processes. The worker holds the same private data-directory lock as the legacy launcher. When upgrading from the legacy LaunchAgent, stop it using its existing installation before registering the packaged worker.

For a version upgrade, stop and unregister the previous packaged worker, keep the previous app available, then open the candidate app and register its login item. Registration first checks the installed data on a private copy. The worker migrates the original in its existing transaction before starting scheduled or Telegram work. If that migration fails, the prior schema remains in place. After a successful migration, keep using a compatible app version so durable delivery receipts and unknown attempts remain intact.

## Removal

Stop and unregister the login item in Delivery & Service. Move the app to Trash. Keep the private data directory by default if you may reinstall. To remove local configuration and history, choose separately to move the private NewsPaw directory in your Library's Application Support to Trash after stopping the worker. Manage Keychain credentials through the app before removal if desired.

## Verification

Local package verification moves the app to a different path, checks the embedded interpreter under a restricted environment, and starts the helper on an isolated fixture directory. A second helper and upgrade preflight both fail while the first helper holds the lock. The private control socket acknowledges stop, and upgrade preflight works after the worker exits. Login approval, restart and logout use a separate clean macOS user or VM. [Apple Service Management sample](https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api)
