# Contributing to Nook

Build new features as Store plugins. Read [the plugin build guide](store/SKILL.md), [API v2](PLUGINS.md#api-v2),
[UI guidelines](docs/UI-GUIDELINES.md) and [current limits](docs/LIMITS.md). Native feature code runs in a separate
helper process; use the host for notch presentation, capabilities and settings. Follow the [Store submission
workflow](store/CONTRIBUTING.md). Do not add a new service to the app when a helper can own it.

For core fixes, use Swift 5/macOS 14.2+, existing BridgeRegistry/SettingsRegistry extension points, and new files
where possible. Build with xcodegen generate and xcodebuild -project Nook.xcodeproj -scheme Nook -configuration
Release -derivedDataPath build build. An explicit -destination 'generic/platform=macOS' avoids Xcode's native/
Rosetta destination-selection warning and verifies both architectures. Compiler warnings must be fixed.

Run bash tests/engine/run.sh, bash tests/store/run.sh, and npm --prefix store test for engine/Store changes;
run affected feature suites too. Test in temporary directories and use mocked window.nook. Never launch a
second Nook instance, type into user apps, or change live data while testing. Keep public native helper builds
reproducible and document signing/notarization and third-party dependencies. Only submit/publish when authorized.
