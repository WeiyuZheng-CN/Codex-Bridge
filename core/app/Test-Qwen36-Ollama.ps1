[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$endpoint = 'http://127.0.0.1:11434'
$sourceModel = 'qwen3.6:35b-a3b-coding'
$model = 'qwen3.6-35b-a3b-coding'
$requestedContextLength = 262144
$outJson = Join-Path $scriptRoot 'qwen36-ollama-verification.json'
$outText = Join-Path $scriptRoot 'qwen36-ollama-verification.txt'

try {
    $health = Invoke-RestMethod -Uri "$endpoint/api/version" -TimeoutSec 10
    $tags = Invoke-RestMethod -Uri "$endpoint/api/tags" -TimeoutSec 20
}
catch {
    throw 'Ollama is not running. Start Start-Qwen36-Ollama.ps1 first.'
}
$names = @($tags.models | ForEach-Object { [string]$_.name })
if ($names -notcontains $model -and $names -notcontains ($model + ':latest')) {
    if ($names -contains $sourceModel -or $names -contains ($sourceModel + ':latest')) {
        throw "Ollama source model exists but alias '$model' is missing. Start Start-Qwen36-Ollama.ps1 to create the local alias."
    }
    throw "Ollama model '$sourceModel' is not installed."
}

$models = Invoke-RestMethod -Uri "$endpoint/v1/models" -TimeoutSec 20
$modelIds = @($models.data | ForEach-Object { [string]$_.id })
if ($modelIds -notcontains $model -and $modelIds -notcontains ($model + ':latest')) {
    throw "Ollama OpenAI-compatible endpoint does not list '$model'."
}

$textBody = @{
    model = $model
    instructions = 'Return the exact answer 2 and nothing else.'
    input = 'Reply with 2 only.'
    reasoning_effort = 'max'
    stream = $false
    store = $false
} | ConvertTo-Json -Depth 12
$textResult = Invoke-RestMethod -Uri "$endpoint/v1/responses" -Method Post `
    -ContentType 'application/json' -Body $textBody -TimeoutSec 300
$textAnswer = @(
    $textResult.output |
        Where-Object { $_.type -eq 'message' } |
        ForEach-Object { $_.content | ForEach-Object { [string]$_.text } }
) -join ''
if ($textResult.status -ne 'completed' -or [string]::IsNullOrWhiteSpace($textAnswer)) {
    throw 'Ollama Responses text test did not return a final message.'
}
$running = Invoke-RestMethod -Uri "$endpoint/api/ps" -TimeoutSec 20
$runningModel = @(
    $running.models |
        Where-Object {
            [string]$_.name -eq $model -or
            [string]$_.name -eq ($model + ':latest')
        }
) | Select-Object -First 1
$activeContextLength = 0
if (-not $runningModel -or -not [int]::TryParse([string]$runningModel.context_length, [ref]$activeContextLength)) {
    throw 'Ollama did not report the loaded Local Qwen context through /api/ps.'
}
if ($activeContextLength -lt $requestedContextLength) {
    throw "Ollama loaded only $activeContextLength tokens; expected $requestedContextLength."
}

$toolBody = @{
    model = $model
    instructions = 'Call the probe function exactly once. Do not provide a final answer.'
    input = 'Call probe with value ok.'
    tools = @(@{
        type = 'function'
        name = 'probe'
        description = 'Returns a probe result.'
        parameters = @{
            type = 'object'
            properties = @{ value = @{ type = 'string' } }
            required = @('value')
        }
    })
    tool_choice = 'required'
    reasoning_effort = 'max'
    max_output_tokens = 2048
    stream = $false
    store = $false
} | ConvertTo-Json -Depth 20
$toolResult = Invoke-RestMethod -Uri "$endpoint/v1/responses" -Method Post `
    -ContentType 'application/json' -Body $toolBody -TimeoutSec 300
$functionCall = @($toolResult.output | Where-Object { $_.type -eq 'function_call' }) | Select-Object -First 1
if ($toolResult.status -ne 'completed' -or -not $functionCall) {
    throw 'Ollama Responses tool test did not return a structured function_call.'
}
$arguments = [string]$functionCall.arguments
if ($functionCall.name -ne 'probe' -or $arguments -notmatch '"value"\s*:\s*"ok"') {
    throw 'Ollama function_call had an unexpected name or argument.'
}

$followBody = @{
    model = $model
    previous_response_id = $toolResult.id
    input = @(@{
        type = 'function_call_output'
        call_id = $functionCall.call_id
        output = 'probe result: ok'
    })
    reasoning_effort = 'max'
    max_output_tokens = 2048
    stream = $false
    store = $false
} | ConvertTo-Json -Depth 15
$followResult = Invoke-RestMethod -Uri "$endpoint/v1/responses" -Method Post `
    -ContentType 'application/json' -Body $followBody -TimeoutSec 300
$followAnswer = @(
    $followResult.output |
        Where-Object { $_.type -eq 'message' } |
        ForEach-Object { $_.content | ForEach-Object { [string]$_.text } }
) -join ''
if ($followResult.status -ne 'completed' -or [string]::IsNullOrWhiteSpace($followAnswer)) {
    throw 'Ollama tool-result continuation did not return a final message.'
}

$blackPngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='
$imageBody = @{
    model = $model
    instructions = 'Describe the image in one short sentence.'
    input = @(@{
        role = 'user'
        content = @(
            @{ type = 'input_text'; text = 'What is in this image?' },
            @{ type = 'input_image'; image_url = "data:image/png;base64,$blackPngBase64" }
        )
    })
    reasoning_effort = 'max'
    max_output_tokens = 1024
    stream = $false
    store = $false
} | ConvertTo-Json -Depth 20
$imageResult = Invoke-RestMethod -Uri "$endpoint/v1/responses" -Method Post `
    -ContentType 'application/json' -Body $imageBody -TimeoutSec 300
$imageAnswer = @(
    $imageResult.output |
        Where-Object { $_.type -eq 'message' } |
        ForEach-Object { $_.content | ForEach-Object { [string]$_.text } }
) -join ''
if ($imageResult.status -ne 'completed' -or [string]::IsNullOrWhiteSpace($imageAnswer)) {
    throw 'Ollama Responses image test did not return a final message.'
}

$gpu = (nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader | Out-String).Trim()
$summary = [ordered]@{
    tested_at_utc = [DateTime]::UtcNow.ToString('o')
    ollama_version = [string]$health.version
    endpoint = $endpoint
    model = $model
    requested_context_length = $requestedContextLength
    active_context_length = $activeContextLength
    model_ids = $modelIds
    text_status = $textResult.status
    text_answer = $textAnswer
    function_call_status = $toolResult.status
    function_call_name = $functionCall.name
    function_call_arguments = $arguments
    tool_followup_status = $followResult.status
    tool_followup_answer = $followAnswer
    image_status = $imageResult.status
    image_answer = $imageAnswer
    nvidia = $gpu
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outJson -Encoding UTF8
@(
    "Ollama version: $($health.version)"
    "Model: $model"
    "Context: $activeContextLength / $requestedContextLength tokens"
    "Text Responses: $($textResult.status)"
    "Structured function call: $($functionCall.name) $arguments"
    "Tool follow-up: $($followResult.status)"
    "Image Responses: $($imageResult.status)"
    "Image answer: $imageAnswer"
    "NVIDIA: $gpu"
    "JSON: $outJson"
) | Set-Content -LiteralPath $outText -Encoding UTF8
Get-Content -LiteralPath $outText
