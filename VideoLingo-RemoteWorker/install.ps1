$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git이 필요합니다.' }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw 'Python 3.10~3.13이 필요합니다.' }

if (Test-Path -LiteralPath '.\STTLMMServer\.git') {
    git -C STTLMMServer pull --ff-only
} else {
    git clone https://github.com/randykwon/STTLMMServer.git STTLMMServer
}
python -m venv .venv
& .\.venv\Scripts\python.exe -m pip install --upgrade pip
& .\.venv\Scripts\pip.exe install -e '.\STTLMMServer[cpu,llamacpp,audio]'
Write-Host 'STTLMMServer 설치 완료. .\start.ps1 로 실행하세요.'
