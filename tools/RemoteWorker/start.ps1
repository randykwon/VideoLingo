$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
Get-Content -LiteralPath .env | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#')) {
        $name, $value = $line -split '=', 2
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}
if (-not $env:STTLMM_API_KEY) { throw 'STTLMM_API_KEY가 필요합니다.' }
$env:STTLMM_SERVER__API_KEYS = '["' + $env:STTLMM_API_KEY + '"]'
$port = if ($env:STTLMM_PORT) { $env:STTLMM_PORT } else { '8848' }
$profile = if ($env:STTLMM_PROFILE) { $env:STTLMM_PROFILE } else { 'balanced' }
& .\.venv\Scripts\sttlmm.exe serve --host 0.0.0.0 --port $port --profile $profile
