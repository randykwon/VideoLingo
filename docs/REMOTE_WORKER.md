# VideoLingo와 STTLMMServer 연결

VideoLingo의 원격 STT·LLM 처리는 [randykwon/STTLMMServer](https://github.com/randykwon/STTLMMServer) API를 기준으로 한다.

- 상태: `GET /health`
- 성능 및 슬롯: `GET /v1/system`
- STT: `POST /v1/audio/transcriptions`
- 번역: `POST /v1/translate`
- 기본 포트: `8848`
- 인증: `Authorization: Bearer <API key>`

대량 번역에서는 영상을 STT API로 한 번만 업로드한다. 반환된 타임스탬프 세그먼트를 최대 200개씩 묶어 각 대상 언어의 번역 API로 보낸다. 여러 STTLMMServer를 등록하면 서버가 보고한 STT/LLM 동시성에 따라 작업을 분산하며, 원격 요청이 실패하면 내장 서버로 전환한다.

## 앱에서 설치 패키지 만들기

1. VideoLingo에서 `설정 > 서버 > STTLMMServer 추가`를 연다.
2. `설치 패키지 저장…`을 누른다.
3. 앱이 생성한 API 키가 포함된 ZIP을 다른 PC로 복사한다.
4. 압축을 풀고 포함된 `README.md`를 따른다.
5. 서버 실행 후 `http://다른-PC-IP:8848`과 같은 API 키를 VideoLingo에 등록한다.

패키지의 스크립트는 공식 GitHub 저장소를 clone/update한 뒤 다음 설치 옵션을 사용한다.

- Apple Silicon: `.[mlx,audio]`
- Windows/Linux CPU 또는 NVIDIA: `.[cpu,llamacpp,audio]`

MP4 처리를 위해 ffmpeg가 필요하다. Windows/Linux 방화벽에서는 같은 LAN에 TCP 8848을 허용한다.

## 직접 설치

STTLMMServer 저장소의 README대로 설치한 다음 외부 PC에서 접근할 수 있도록 실행한다.

```sh
sttlmm serve --host 0.0.0.0 --port 8848 --profile balanced
```

API 키를 설정했다면 VideoLingo에도 동일한 키를 입력한다. 연결 확인은 공개 `/health`뿐 아니라 인증이 필요한 `/v1/system`까지 검사하므로 키가 틀리면 연결 실패로 표시된다.

인터넷이나 신뢰할 수 없는 네트워크를 통과할 때는 VPN 또는 HTTPS 리버스 프록시를 사용한다.
