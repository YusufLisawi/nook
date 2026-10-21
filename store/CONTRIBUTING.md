# Contributing

Fork this repository and add `plugins/<id>/`. IDs are lowercase letters, digits, and dashes, at most 80 characters. The folder must match `plugin.json`'s ID. Choose an ID that doesn't override a bundled Nook tab.

Include a valid `plugin.json`, local HTML/JS/CSS, and `store.json`:

```json
{
  "description": "One clear sentence describing the plugin.",
  "author": "your-github-handle",
  "version": "1.0.0",
  "tags": ["productivity", "offline"],
  "screenshots": ["screenshots/preview.png"]
}
```

Screenshots are relative paths to files inside the plugin; an empty array is allowed. Prefer PNG or JPEG. Versions use `major.minor.patch` with an optional prerelease suffix. If `plugin.json` includes a version, it must match. Bump the version whenever changing a published plugin. Do not edit `index.json` manually.

Use vanilla JavaScript and Nook's injected `nk-*` UI kit. Bundle scripts and styles locally, without CDNs. Keep the page transparent with scrolling inside lists, use one accent, and provide loading/empty/error/ready states. Use `nook.storage` for saved data and settings declarations for user choices. Catch failed bridge calls and explain how to retry. The plugin must be usable with Tab/arrows, Enter, ⌘Enter for a primary editor action, and Escape to close Nook.

See [Nook's plugin reference](https://github.com/YusufLisawi/nook/blob/main/PLUGINS.md) and [UI guidelines](https://github.com/YusufLisawi/nook/blob/main/docs/UI-GUIDELINES.md).

Packages are limited to 200 files, 5 MB per file, and 20 MB total. Include regular, non-executable files only. No symlinks, submodules, hidden files, absolute paths, path traversal, duplicate names differing only in case, or secrets. Explain any network access or shell commands in a plugin README, including why they are necessary. Do not include tracking, downloads of executable code, or third-party code without permission and license notices.

Before opening a PR:

```sh
nook validate ./plugins/my-plugin
node scripts/validate.mjs ./plugins/my-plugin
npm test
```

Test your plugin's logic with a mocked `window.nook`. Include manual keyboard checks and screenshots at the supported height in the PR. Maintainers review behavior and source before merging. CI checks packaging; passing CI alone does not establish trust.

Alternatively, `nook publish <path>` validates and shows exactly which files will be submitted. Add `--yes` only after reviewing the plan. GitHub CLI (`gh`) must be installed and authenticated. The command creates a fork if needed, adds a contribution branch, and opens a PR without modifying your current Git checkout. An unsuccessful submission may leave a remote branch; it never merges the PR.
