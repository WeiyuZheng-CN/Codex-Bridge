# Legacy compatibility note

The current release uses native DeepSeek, shared Transfer `auth.json`, and one
older launcher. Older releases contained Moon Bridge, a second native
DeepSeek path, a second Transfer profile, and history-repair helpers.

Those components are intentionally not part of the active package. Their
sanitized source, binary, license, and helper files are retained under
archive/legacy-moon-bridge, while the 260902 configuration references are
under archive/legacy-transfer-260902. They are also recoverable from Git
commit `0924440` and earlier release commits if an old installation needs a
one-time migration or rollback.

Nothing under archive/ is loaded by the current installer or chooser. Do not
copy runtime state, credentials, sessions, databases, or logs into the
archive.

Do not copy old runtime data into this package. Preserve existing user
profiles, sessions, Electron data, logs, and credentials in place. If an old
profile requires the 260902 API Key Mode with `SUB2API_API_KEY` or an actor
header, let an AI agent adapt that installed profile after making a backup.

The current source of truth for Transfer behavior is:

- <https://docs.ai-pixel.online/docs/api>
- <https://docs.ai-pixel.online/docs/api/responses>
- <https://docs.ai-pixel.online/docs/api/models>
- <https://docs.ai-pixel.online/docs/normal-client-setup>
- <https://docs.ai-pixel.online/docs/normal-account-mode>
