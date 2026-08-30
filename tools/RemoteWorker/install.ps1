$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'Python 3.11 이상을 먼저 설치하세요.'
}
python -m venv .venv
& .\.venv\Scripts\python.exe -m pip install --upgrade pip
& .\.venv\Scripts\pip.exe install -r requirements.txt

if (-not (Test-Path -LiteralPath .env)) {
    $token = & .\.venv\Scripts\python.exe -c 'import secrets; print(secrets.token_urlsafe(32))'
    @"
VIDEOLINGO_TOKEN=$token
VIDEOLINGO_NAME=$env:COMPUTERNAME
VIDEOLINGO_PORT=8765
VIDEOLINGO_STT_SLOTS=1
VIDEOLINGO_TRANSLATION_SLOTS=1
OLLAMA_URL=http://127.0.0.1:11434
OLLAMA_MODEL=qwen3:8b
WHISPER_MODEL=large-v3
WHISPER_DEVICE=auto
WHISPER_COMPUTE_TYPE=auto
"@ | Set-Content -LiteralPath .env -Encoding utf8
}
Write-Host '설치 완료. Ollama 모델을 받은 뒤 .\start.ps1 을 실행하세요.'
