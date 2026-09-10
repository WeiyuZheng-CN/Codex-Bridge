# DeepSeek native configuration reference 260909

This directory records the public shape of the newest DeepSeek native setup.
It contains no API key, personal path, or account data.

Official reference: <https://api-docs.deepseek.com/guides/vision>

The native Codex profile uses:

```toml
model_provider = "deepseek"
base_url = "https://api.deepseek.com/"
wire_api = "responses"
```

`native-config.example.toml` shows the corresponding credential-free Codex
shape. The `Deepseek.txt` file supplied by the user is an API usage example,
not a file to copy into the repository; any key from it must remain local.

The model catalog should expose these models through the same DeepSeek
entrance:

- `deepseek-v4-pro`
- `deepseek-v4-flash`
- `deepseek-v4-flash-vision-exp`

The vision model accepts JPEG, PNG, GIF, and WebP. With the Responses API,
images are supplied as `input_image` content parts. The official guide also
documents base64 data URLs, public image URLs, and Files API `file_id` inputs.

When installing, the agent should use the native profile and let the user
choose the model inside Codex. Moon Bridge is retained only as a historical
compatibility resource.

For the current key, ask the user to visit
<https://ai-pixel.online/keys> and click **使用密匙**. Keep the resulting key
outside this repository and never paste it into an AI conversation.
