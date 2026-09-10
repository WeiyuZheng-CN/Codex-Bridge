# Codex Vibe Software: installed maintenance guide

This is an AI-maintained local installation. Read `launcher.settings.json` and
`install-manifest.json` before changing it. They describe the physical app
path, profile roots, selected modes, and package version, but contain no keys.

## Current architecture

```text
Codex desktop shortcut
  -> Start-Codex-Chooser.ps1
     -> ChatGPT profile
     -> DeepSeek -> native DeepSeek Responses API
          -> Codex model picker: V4 Pro / V4 Flash / V4 Flash Vision
     -> OpenAI Transfer -> shared auth.json profile -> station API
          -> Pro/Legacy selected in the station web console
```

The main chooser has one DeepSeek card. The native DeepSeek profile exposes
`deepseek-v4-pro`, `deepseek-v4-flash`, and
`deepseek-v4-flash-vision-exp` through the same provider entrance. The vision
model accepts JPEG, PNG, GIF, and WebP images as Responses API `input_image`
parts. The former Moon Bridge route remains in the application only as a
historical compatibility resource.

The current public reference is `configuration\260909`. An old
`NativeFlash` installer argument may still appear in a user's history, but it
maps to this same native DeepSeek entry; it must not create a second card or a
second model-selection dialog.

Provider profiles and Electron data are isolated. ChatGPT uses the normal
Codex profile as-is. The shared Transfer profile uses one station key in
`auth.json`; the web console chooses Pro or Legacy routing for that key. The
historical 260902 API Key Mode profile may remain under `legacy-transfer` for
rollback when a station still requires an environment key or actor header.

For current station behavior, read:

- <https://docs.ai-pixel.online/docs/api>
- <https://docs.ai-pixel.online/docs/api/responses>
- <https://docs.ai-pixel.online/docs/api/models>
- <https://docs.ai-pixel.online/docs/normal-client-setup>
- <https://docs.ai-pixel.online/docs/normal-account-mode>

When a key or generated configuration is needed, have the user open
<https://ai-pixel.online/keys> and click **使用密匙**. Keep the result private.

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

If the station changes its generated configuration, compare the current
**使用密匙** output with the shared profile. Keep one profile when both web
modes use the same `auth.json` shape; retain or restore `legacy-transfer` when
API Key Mode or an actor header is required.

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
