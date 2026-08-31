# STTLMMServer 설치 및 VideoLingo 연결

이 패키지는 [randykwon/STTLMMServer](https://github.com/randykwon/STTLMMServer)를 설치하고 VideoLingo용 API 키로 실행합니다. `.env`의 `STTLMM_API_KEY`는 외부에 공개하지 마세요.

## Linux/macOS

Python 3.10~3.13, Git, ffmpeg를 설치한 뒤 실행합니다.

```sh
chmod +x install.sh start.sh
./install.sh
./start.sh
```

## Windows PowerShell

Python 3.10~3.13, Git, ffmpeg와 C++ 빌드 도구를 설치한 뒤 실행합니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install.ps1
.\start.ps1
```

서버가 시작되면 브라우저에서 `http://이-PC의-IP:8848/admin`을 열어 모델과 성능 설정을 확인할 수 있습니다. 방화벽에서 같은 LAN에 대해 TCP 8848을 허용하고, VideoLingo에는 `http://이-PC의-IP:8848`과 `.env`의 API 키를 등록하세요.
