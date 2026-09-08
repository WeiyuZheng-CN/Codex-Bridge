# Codex Vibe Software: installed maintenance guide

This is an AI-maintained local installation. Read `launcher.settings.json` and
`install-manifest.json` before changing it. They describe the physical app
path, profile roots, selected modes, and package version, but contain no keys.

## Current architecture

```text
Codex desktop shortcut
  -> Start-Codex-Chooser.ps1
     -> ChatGPT profile
     -> DeepSeek V4 Pro -> local Moon Bridge -> DeepSeek
     -> DeepSeek V4 Flash -> native DeepSeek Responses API
     -> OpenAI Transfer -> concise Pro/Legacy selector -> station API
```

The chooser stays visually minimal. Modes not listed in `enabled_modes` are
visible but dimmed. Do not diagnose a dim card as a WPF failure; configure its
profile and add the mode when the user wants it.

Provider profiles and Electron data are isolated. ChatGPT uses the normal
Codex profile as-is. Transfer Pro and Legacy remain separate because their
credentials and authentication shapes may differ even when their endpoint is
the same.

## Agent maintenance rule

The agent may adapt this installation to a new Codex build, provider revision,
model, endpoint, authentication shape, path, or user-requested feature. Before
replacing a working file:

1. inspect the real behavior and current profile;
2. save a dated copy of the affected file;
3. make the smallest understandable change;
4. record it in `LOCAL-CHANGES.md` with reason and rollback path;
5. parse edited PowerShell and run the affected `-ValidateOnly` or UI preview.

Do not require every unrelated mode or remote API to pass before accepting a
local change. `SKIPPED` means a mode is not configured. A local `OK` result is
not proof of remote key, quota, account, or station availability.

## Boundaries

- Never expose or copy values from `auth.json`, generated `config.yml`, or
  secret-bearing profile settings into chat, logs, screenshots, source, or a
  shareable archive.
- Do not silently rewrite `%USERPROFILE%\.codex`.
- Ask before deleting personal state, changing an external account, installing
  untrusted software, or publishing files.
- Do not terminate the Codex process hosting the current agent task.
- Do not recursively delete through the friendly `Codex-Launcher` junction.

When a useful feature should be shared, export only sanitized source,
templates, prompts, and documentation—not the configured installation.

