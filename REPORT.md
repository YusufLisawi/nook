# Agents

Implemented on `agent/agents`. No new third-party dependencies.

## What is included

- Native agent definitions with the requested defaults, model-cache discovery, grouped Settings editor, folder picker, reasoning choices, explicit full-access warning, automatic saves and Trash-based history removal.
- Real Codex CLI turns and resumable chats. Uses the existing `CodexLink` lookup, `codex exec --json`, `developer_instructions`, stdin prompts, per-agent model/effort/folder/access settings, and `exec resume <codexSessionId> -` for follow-ups. Exec-level flags precede `resume`, since its subcommand does not accept `-C`/`-s` directly.
- JSONL item snapshots for messages, reasoning summaries, commands/output/exit status, file changes, web search, MCP and collaboration calls, plans, errors and token usage. Turn-scoped item IDs prevent resume collisions. Each turn has a dedicated process group; stop also enumerates descendants, including children in their own groups.
- Private, atomic JSON history under `AgentSessions/<agentId>/<sessionId>.json` and definitions in `agents.json`. Startup marks unfinished turns interrupted. Corrupt storage is surfaced without overwriting it.
- Bundled Agents plugin, order 17 and height 400: agents/recent chats, quick switcher, safe Markdown/code copying, collapsible tool cards, bounded file previews, running/empty/loading/error states, drafts per chat, stop/new/send shortcuts, pinning and background activity. A hidden Agents view releases only pins it requested.

## Files touched

- New: `Nook/Services/Agents/{AgentModels,AgentProcess,AgentDiff,AgentService,AgentsPane}.swift`.
- New: `Plugins/agents/{plugin.json,index.html,core.js,main.js,markdown.js,style.css}`.
- New: `Tests/Agents/` native/process fixtures and DOM-independent plugin tests, plus this report.
- Shared: two lifecycle lines in `Nook/Core/Services.swift`; API documentation in `PLUGINS.md`; capabilities/limits in `docs/LIMITS.md`.
- Build: regenerated `Nook.xcodeproj/project.pbxproj`. `project.yml` disables unused App Intents metadata extraction (`LM_SKIP_METADATA_EXTRACTION`) to avoid Xcode's empty-extraction warning; compiler warnings remain enabled.

## Verification completed

- Required `xcodegen generate && xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release -derivedDataPath build build`: passed with zero errors and zero compiler warnings. Xcode itself emits one pre-existing destination-selection warning because this Apple Silicon Mac offers native and Rosetta destinations. Build log: `/tmp/nook-agents-build-review.log`. The additional build with `-destination 'platform=macOS,arch=arm64'` passes with **zero warnings of any kind** (`/tmp/nook-agents-build-explicit-destination.log`). The exact command's destination warning remains; no architecture support was removed to hide it.
- `nook validate Plugins/agents`: passed.
- `bash Tests/Agents/run.sh`: passed. Compiles the native service in Swift 5/macOS 14.2 mode with warnings as errors, using a mock executable and injected support folder entirely under `/tmp`. Covers split UTF-8 JSONL, live command snapshots, usage, file previews, persistence/reload, resumed item IDs, literal stdin prompts, errors, concurrent-turn rejection and cancellation of a child in a separate process group. JavaScript runs from `/tmp` with mocked `window.nook`; covers message sending, stale reply ordering, selection races, drafts, safe Markdown, code copying, quick switch/new/stop, tool expansion preservation, creation, activity and pin ownership.
- The earlier run's **one** cheap real `gpt-6-luna`/low turn in `/tmp` succeeded: it said hi and executed `ls`. Its saved JSONL (`/tmp/nook-agents-codex-probe.jsonl`) was reviewed; no additional model calls were made. Installed CLI: 0.163.0. Both help pages and the parent-flags/resume parser were checked. `developer_instructions` was checked against the config reference; the exec event schema was reviewed.
- Bundled plugin resources confirmed inside the built app. `git diff --check` passed.
- Nook was never launched. No GUI automation, writes to the user's Nook support data, changes to `/Applications`, release scripts, pushes or merges were performed. Visual behavior in a running Nook remains for the lead to review.

## Lead test steps

1. Run the build, validator and `bash Tests/Agents/run.sh` commands above. Tests use `/tmp`, never your live Nook support folder.
2. When ready for manual review, quit the existing Nook instance before running the built copy. Open Settings → Agents, create an agent, edit a multiline instruction and choose a disposable working folder. Check model/reasoning pickers and the full-access warning; try full access off as well.
3. Open the Agents tab, or create an agent with **+**. Send a request to list files, create a tiny file and explain the result with a list/code block. Expand shell/file cards; check output, exit badges, the file preview and copy button. Follow up in the same chat and verify Codex retains context.
4. Try Enter, Shift+Enter, ⌘Enter, ⌘K/arrows/Enter, ⌘N, Tab, Esc and ⌘. Start a long-running shell command in the disposable folder and stop it. Switch tabs/close the chat and confirm unpinning; close the notch during a turn and check the sparkles activity clears on completion.
5. Restart Nook and reopen a saved chat. Test a missing folder or inaccessible model for inline errors. Delete an idle agent and confirm its Nook history appears in Trash. Running chats must be stopped before deletion.

## Limits and risks

- Codex supplies the user's configured tools/login. Model access and supported reasoning levels depend on the account/model. Sandbox mode is `workspace-write` with approval policy `never`; blocked requests fail instead of opening an approval UI. Full access defaults to on as requested.
- Codex 0.163 emits item snapshots, so text/output streaming granularity depends on the CLI. A real resume/tool-edit/MCP round trip was not run; resume syntax and event handling are covered by help/schema checks and mocks.
- File-change events contain paths/kinds, not patches. Cards explicitly label bounded working-tree previews, which may include pre-existing changes; non-Git updates may have no diff. Added files get a bounded content preview.
- History is local, unencrypted JSON with 0600 files and no automatic retention/size limit. Existing chats are loaded into memory at startup. Codex retains its own history separately; deleting an agent trashes only Nook's history.
- Cancellation kills local groups/descendants. Already-detached daemons and remote tool side effects cannot be undone. Quitting saves interrupted state for later resume.
- Shared-file merge surface is limited to lifecycle registration/shutdown, documentation and generated project/build settings. After merging parallel work, regenerate the Xcode project.
