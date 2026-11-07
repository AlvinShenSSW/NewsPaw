# NewsPaw native settings

Build and test on macOS 14 or later with a Swift 6 toolchain.

```sh
swift build --package-path macos/NewsPaw
swift test --package-path macos/NewsPaw
macos/NewsPaw/build-dev-app.sh
```

The development bundle is written to `macos/NewsPaw/.build/NewsPaw.app`. Open it in Finder to use the real settings window and menu bar item. It connects to `~/Library/Application Support/NewsPaw/control.sock`. The app and background service are separate processes.

For an isolated UI check, run the Python backend with `uv run newspaw control --data-dir /tmp/your-private-test-directory` and build the app with `--fixture-socket /tmp/your-private-test-directory/control.sock`. Use a newly created private directory and no real credentials. Add `--appearance light` or `--appearance dark` to check either appearance without changing system settings. The development bundle does not install a service or create a launch agent.

Check all five sidebar pages and the two language pickers. The display language updates the window immediately. News language remains an independent backend setting. Close the window, then reopen it from the NewsPaw menu bar item. Quit Settings leaves the backend running. Stop Backend asks the local control service to exit cleanly. The app clears backend lists and reports disconnection once the service exits.

The bundled logo and AV icon are exact copies of the approved preview assets in `assets/branding`. The remaining category symbols use system icons.
