# Plugin Store

The Store lives in a standalone public `YusufLisawi/nook-plugins` repository, prepared under `store/`. Its catalog is generated from validated plugin folders. Each catalog entry includes a Git tree SHA, so the app and CLI verify files against an immutable revision. Raw CDN files are accepted only when their blob hashes match that tree, with immutable blobs as a fallback. Concurrent changes on `main` cannot produce a mixed installation. This also lets the generator work before the new repository exists.

A Foundation-only client is compiled into both targets. It caches the catalog, validates downloads in a staging directory, records installed versions in each plugin folder, refuses to overwrite unrelated or edited copies, and moves removed/replaced copies to Trash. Per-plugin file locks coordinate app and CLI operations. Settings and saved plugin data remain independent of installation.

A registered SwiftUI grouped Form provides search, a list, details, screenshots, install/update/uninstall, and copyable install links. Deep links select details and never install automatically. A missing public repository produces a friendly empty state; network failures use cached entries.

The CLI adds catalog search, installation, updates, and uninstall. Publishing validates the folder and Store metadata, prints a concrete plan, and requires `--yes` before any remote mutation. It uses `gh` Git data APIs to create a contribution branch and PR without changing the developer's current checkout.

Alternatives considered: tarball extraction is simpler to request but downloads the entire repository and adds archive traversal concerns; mutable Contents API downloads are easy to implement but can mix revisions. Immutable Git trees/blobs provide a small, verifiable package without dependencies.

Validation uses isolated temporary directories and mocked networking, repository validator fixtures, and a mocked `window.nook` for the example plugin. Nook is never launched and live Nook data is never changed. The final required Release build must produce no warnings or errors.
