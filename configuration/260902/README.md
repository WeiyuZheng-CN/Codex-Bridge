# Transfer station configuration 260902

These are sanitized, account-independent configuration references for the
260902 transfer-station setup. They preserve the provider, model, endpoint,
wire protocol, and authentication shape, but contain no usable API key or
actor-authorization value.

Available model examples:

- `gpt-5.6-luna`
- `gpt-5.6-sol`
- `gpt-5.6-terra`

Two authentication modes are represented:

- `api-key-mode-*.toml`: `requires_openai_auth = false`, with
  `SUB2API_API_KEY` and an actor-authorization placeholder;
- `auth-json-mode-*.toml`: `requires_openai_auth = true`, with the API key
  stored separately using `auth.example.json` as the shape reference.

## Instructions for the installation agent

When current transfer configuration or credentials are needed, ask the user
to open <https://ai-pixel.online/keys> and click **使用密匙**. The user should
save the information shown there to a private file outside this repository, or
enter the requested value into the installer's local hidden prompt.

Never ask the user to paste the page contents, API key, actor-authorization
value, or complete authorization header into an AI conversation. Never copy
those values into this directory or commit them. Compare the current station
information with these 260902 references and adapt the generated local profile
if the station has changed.

