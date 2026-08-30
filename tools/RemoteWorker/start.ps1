$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

Get-Content -LiteralPath .env | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#')) {
        $name, $value = $line -split '=', 2
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}
$port = if ($env:VIDEOLINGO_PORT) { $env:VIDEOLINGO_PORT } else { '8765' }
& .\.venv\Scripts\uvicorn.exe server:app --host 0.0.0.0 --port $port
