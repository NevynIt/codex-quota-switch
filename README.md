Version 2.3.2

# Codex Provider Router + Quota Watcher — Windows

This package routes Codex between:

- your normal **ChatGPT subscription** while included Codex usage is available;
- your **metered OpenAI API project** when the subscription is depleted and you approve fallback.

It supports both the standalone Codex CLI and the Codex VS Code extension, including reopening the **same thread** under the newly selected provider.

## Why the watcher is not a Windows service

The watcher is a hidden **per-user background process** started at Windows logon.

That is intentional:

- it needs your existing Codex/ChatGPT login;
- the API key is protected with Windows DPAPI in your user context;
- it must display confirmation dialogs in your desktop session;
- it keeps running while the workstation is locked (but naturally stops when you sign out);
- no administrator/service account is needed.

Modern Windows services run in Session 0 and cannot directly display ordinary UI in the logged-in user's session. A traditional service would therefore require a second UI agent and user impersonation anyway.

## Normal watcher behavior

The watcher polls `account/rateLimits/read` every **10 minutes**.

The authoritative switch signal is:

```text
ordinaryUsageAllowed
```

### When subscription usage is available

Default provider remains:

```toml
model_provider = "openai"
```

### When the subscription is depleted

If you are present, a timed Yes/No/Cancel dialog appears:

- **Yes** — switch the default to metered API until the subscription recovers;
- **No** — stay on subscription for this depletion cycle;
- **Cancel** — ask again in 30 minutes;
- **no answer / timeout** — do **not** enable billable API; ask again later.

Existing running Codex sessions are never killed or automatically migrated.

### Reset handling

Codex exposes `resetsAt` timestamps for its rate-limit windows. The watcher uses them only as advisory scheduling hints.

It wakes/rechecks:

- shortly before the predicted reset, to warn you;
- about 15 seconds after the predicted reset;
- once per minute for a short grace period if recovery is delayed.

It switches back only after the backend explicitly returns:

```text
ordinaryUsageAllowed = true
```

When recovery is confirmed, it warns you and changes the **default** back to the ChatGPT subscription. Existing API sessions continue until they finish or you reload them.

## Overnight safety

The default is intentionally conservative:

> **No user response means no automatic API fallback.**

So an unattended job cannot silently enter metered API merely because subscription quota ran out overnight.

### Explicit unattended API lease

If you intentionally want overnight continuity:

```powershell
codex-api-lease -Hours 8
```

or:

```powershell
codex-api-lease -Until "2026-09-21 08:00"
```

While the lease is active, the watcher may switch the default to API without a live confirmation.

Check it:

```powershell
codex-api-lease -Status
```

Cancel it:

```powershell
codex-api-lease -Clear
```

When the lease expires while subscription usage is still depleted, the watcher returns the **default** provider to subscription so new/resumed work does not automatically enter API.

Important: an already-running API-backed Codex session is deliberately **not stopped** at lease expiry.

## Strongly recommended spending backstop

Use a **dedicated OpenAI API project** for this fallback key and configure an **enforced hard spend limit** on that project.

That is the only reliable local-independent protection against an already-running unattended API session continuing to consume tokens after you leave.

Also restrict the project/model access to what you actually need.

## Installation

Prerequisite: the standalone `codex.exe` is already on PATH.

Extract this ZIP and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
```

The installer:

1. records your real `codex.exe`;
2. installs commands in `%LOCALAPPDATA%\CodexQuotaSwitch\bin`;
3. adds that directory to your user PATH;
4. configures the `openai-api` provider;
5. builds the VS Code provider-routing facade;
6. configures `chatgpt.cliExecutable` when safe;
7. enables the hidden quota watcher at logon;
8. starts the watcher immediately;
9. backs up relevant Codex/VS Code configuration before modifying it.

Options:

```powershell
.\install.ps1 -SkipWatcher
.\install.ps1 -SkipVSCodeProxy
.\install.ps1 -ForceVSCodeProxy
```

## Store the API key

```powershell
codex-api-key set
codex-api-key test
```

The key is stored as a DPAPI-protected blob under:

```text
%LOCALAPPDATA%\CodexQuotaSwitch\secret\
```

It is not stored as plaintext in `config.toml` or a persistent environment variable.

Your normal Codex login remains:

```powershell
codex login status
```

```text
Logged in using ChatGPT
```

That is expected even while model traffic is routed through `openai-api`.

## Watcher commands

```powershell
codex-quota-watch-status
codex-quota-watch-stop
codex-quota-watch-start
codex-quota-watch-start -Restart
```

A one-off raw quota read:

```powershell
codex-quota-read
```

Machine-readable:

```powershell
codex-quota-read -Json
```

Log:

```text
%LOCALAPPDATA%\CodexQuotaSwitch\watcher.log
```

State:

```text
%LOCALAPPDATA%\CodexQuotaSwitch\watcher-state.json
```

## Manual routing

The original commands remain available:

```powershell
codex-route -StatusOnly
codex-route -ForceApi
codex-route -ForceSubscription
```

## One facade for CLI and VS Code

There is only one routing executable:

```text
%LOCALAPPDATA%\CodexQuotaSwitch\bin\codex.exe
```

The installer does two things with that same file:

1. puts `%LOCALAPPDATA%\CodexQuotaSwitch\bin` first on your **user PATH**, so ordinary shell `codex` calls resolve to the facade;
2. sets VS Code's `chatgpt.cliExecutable` to that exact `codex.exe`.

```text
Shell `codex` ─────┐
                   ├──> CodexQuotaSwitch\bin\codex.exe ───> real codex.exe
VS Code Codex ─────┘
```

The facade detects how it was invoked:

- **CLI/TUI mode:** it reads the currently routed provider and adds the equivalent of `-c 'model_provider="<provider>"'`, unless you explicitly supplied your own `model_provider`. This also makes Codex's internal `/resume` keep the routed provider.
- **VS Code app-server mode:** it proxies JSON-RPC to the real Codex executable and injects `modelProvider` into `thread/start` and `thread/resume` when the extension did not explicitly provide one.

So new CLI sessions, `codex exec`, `codex resume`, internal `/resume`, and reopened VS Code threads all follow the provider chosen by `codex-route` / the watcher.

## Transparent CLI wrapper

The installer also places a wrapper named:

```text
%LOCALAPPDATA%\CodexQuotaSwitch\bin\codex.exe
```

at the front of your **user PATH**.

This is intentionally the same provider-routing proxy used by VS Code.

For ordinary CLI usage:

```powershell
codex
codex exec ...
codex resume ...
```

the wrapper reads the current top-level `model_provider` from `~/.codex/config.toml` and launches the real standalone Codex executable with the equivalent of:

```powershell
-c 'model_provider="<current-provider>"'
```

unless you already supplied your own explicit `model_provider` override.

This is deliberately done for **every ordinary Codex launch**, not only `codex resume`. It places the selected provider in Codex's session-level configuration layer. Therefore, if you start:

```powershell
codex
```

and later type inside the TUI:

```text
/resume
```

Codex's own resume logic sees the provider as an explicit session override and keeps using the provider chosen by `codex-route`, rather than restoring the provider saved in the old thread.

Therefore the intended user model is simple:

1. `codex-route` / the watcher selects `openai` or `openai-api`;
2. use `codex` normally;
3. `codex resume`, internal `/resume`, new CLI sessions, and resumed VS Code threads all use that selected provider.

Examples:

```text
codex
  /resume            -> current routed provider

codex resume <id>    -> current routed provider

codex exec ...       -> current routed provider

VS Code reopen       -> current routed provider
```

After installation or upgrade, open a **new terminal once** so Windows picks up the revised user PATH.

Verify with:

```powershell
Get-Command codex
codex-provider-status
```

`Get-Command codex` should point to:

```text
...\AppData\Local\CodexQuotaSwitch\bin\codex.exe
```

while `codex-provider-status` also shows the separately recorded path of the real standalone Codex executable.

## VS Code

VS Code is explicitly pointed at the **same** `%LOCALAPPDATA%\CodexQuotaSwitch\bin\codex.exe` facade that the shell uses. This is needed because the extension does not rely on your shell PATH for its Codex executable.

The installer uses the extension's `chatgpt.cliExecutable` setting to point at a small local proxy.

The proxy forwards all Codex traffic unchanged except that for `thread/start` and `thread/resume` it injects the current top-level `model_provider` if the extension did not already supply one.

After the watcher changes provider, reload the VS Code window:

```text
Ctrl+Shift+P
Developer: Reload Window
```

You can then reopen the **same conversation**. Existing in-memory sessions are not forcibly stopped.

CLI fallback:

```powershell
codex-vscode-resume
```

This lists VS Code conversations by title and resumes the selected thread with an explicit provider override.

### Conversation visibility across providers

VS Code may ask `thread/list` with a `modelProviders` filter. Because a conversation is recorded with the provider it originally used, that can hide old subscription conversations while `openai-api` is selected (and vice versa).

The facade therefore rewrites only the VS Code app-server `thread/list` request so:

```json
"modelProviders": []
```

An empty provider list is defined by Codex as **include all providers**.

This does not modify or migrate rollout files. The historical conversation keeps its original provider metadata. When you actually reopen one, the separate `thread/resume` rewrite supplies the provider currently selected by `codex-route`.

So the model is:

```text
thread/list   -> show conversations from every provider
thread/resume -> execute selected conversation on current routed provider
```

That avoids destructive or lossy one-time migration of old chat metadata.

## Full status

```powershell
codex-provider-status
```

This shows provider routing, API-key state, VS Code facade status, subscription allowance, and watcher state.

## Uninstall

```powershell
.\uninstall.ps1
```

This stops/removes the logon watcher, restores/disables the VS Code facade where possible, removes the installed commands/PATH entry, and removes the DPAPI-protected key unless told otherwise.

The harmless custom provider block in `~/.codex/config.toml` is intentionally left in place.
