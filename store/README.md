# Nook Plugin Store

Small, open-source plugins for [Nook](https://github.com/YusufLisawi/nook), the macOS notch app. This repository is the community catalog and the source of every package. No account or server is needed to browse or install.

## Browse & install

Open **Nook Settings → Plugin Store**, search by name, author, or tag, and select a plugin to review its source and details. Click **Install**. Updates appear in the same pane; **Uninstall** moves the plugin to Trash and keeps its saved data and settings.

With a version of Nook that includes the Store CLI:

```sh
nook search writing
nook install word-count
nook update                 # all Store plugins
nook update word-count
nook uninstall word-count
```

[Word Count](plugins/word-count) is a small offline example. Share a plugin with `nook://install/word-count`; Nook opens its detail and waits for you to click Install. A link never installs automatically. The catalog is cached for offline browsing; installation needs GitHub. GitHub's public API rate limits may temporarily delay downloads.

Plugins can run shell commands as you and access files through Nook. Review the source of plugins you install. Validation checks packaging and common UI mistakes; it is not a security audit. The Store refuses to update a locally edited copy. Back it up before uninstalling and reinstalling the Store version.

## Submit a plugin

See [CONTRIBUTING.md](CONTRIBUTING.md). Add a valid Nook plugin under `plugins/<id>/`, include `store.json`, and open a PR. You can preview an assisted submission locally:

```sh
nook publish ./plugins/my-plugin         # validates and prints a plan; no remote changes
nook publish ./plugins/my-plugin --yes   # uses authenticated gh to fork, branch, upload, and open a PR
```

Submission does not publish immediately. Maintainers review and merge PRs. Bump the version for every change to an existing plugin.

## Repository tools

Node.js 22 or newer; no npm dependencies or installation step:

```sh
npm test
npm run validate
npm run generate
```

`scripts/validate.mjs` ports `nook validate` manifest, settings, offline, transparent-background, and UI checks, plus stricter Store path/size checks. It never executes submitted plugin code. PRs run validation and tests. After a merge to `main`, Actions regenerates and commits `index.json`. Enable Actions write access for the catalog workflow; branch protection must allow the bot's catalog commit (or run the generator as part of your merge process).

The index is a JSON array with `id`, `name`, `description`, `author`, `version`, `symbol`, `tags`, `screenshots`, `path`, `sha`, and `updatedAt`. `sha` is the Git tree SHA-1 for the plugin folder; the native client fetches that immutable tree and verifies every file's blob hash. Current packages use GitHub's raw CDN (usually one API request per installation); an outdated CDN file falls back to its exact Git blob. `updatedAt` is the last plugin change's commit timestamp, preserved when its content hasn't changed. Empty directories aren't packaged. The generated index does not depend on the repository's own commit SHA.

MIT licensed. Contributions must be original or MIT-compatible; keep third-party notices with their files.
