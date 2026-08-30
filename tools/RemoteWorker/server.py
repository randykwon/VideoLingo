"""VideoLingo LAN Worker: faster-whisper STT + Ollama translation."""
import asyncio, json, os, shutil, tempfile, uuid
from pathlib import Path
from fastapi import BackgroundTasks, FastAPI, File, Form, Header, HTTPException, UploadFile
from faster_whisper import WhisperModel
import httpx

app = FastAPI(title="VideoLingo Worker", version="1.0")
TOKEN = os.environ.get("VIDEOLINGO_TOKEN", "")
NAME = os.environ.get("VIDEOLINGO_NAME", "VideoLingo Worker")
STT_SLOTS = int(os.environ.get("VIDEOLINGO_STT_SLOTS", "1"))
TRANSLATION_SLOTS = int(os.environ.get("VIDEOLINGO_TRANSLATION_SLOTS", "1"))
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "qwen3:8b")
WORKER_ID = uuid.uuid5(uuid.NAMESPACE_DNS, NAME)
jobs: dict[str, dict] = {}
semaphore = asyncio.Semaphore(max(1, min(STT_SLOTS, TRANSLATION_SLOTS)))

def auth(value: str | None):
    if not TOKEN or value != f"Bearer {TOKEN}":
        raise HTTPException(401, "invalid worker token")

@app.get("/v1/status")
async def status(authorization: str | None = Header(default=None)):
    auth(authorization)
    return {"apiVersion": 1, "workerID": str(WORKER_ID), "name": NAME, "version": "1.0",
            "activeJobs": sum(v["status"] not in ("completed", "failed", "cancelled") for v in jobs.values()),
            "capabilities": {"sttSlots": STT_SLOTS, "translationSlots": TRANSLATION_SLOTS,
                             "sttModels": ["faster-whisper"], "translationModels": ["ollama"]}}

@app.post("/v1/jobs")
async def create_job(background: BackgroundTasks, manifest: str = Form(), media: UploadFile = File(), authorization: str | None = Header(default=None)):
    auth(authorization)
    data = json.loads(manifest)
    jid = data["jobID"]
    if jid in jobs and jobs[jid]["status"] not in ("failed", "cancelled"):
        return {"jobID": jid, "accepted": True, "message": "existing job resumed"}
    work = Path(tempfile.mkdtemp(prefix="videolingo-worker-"))
    path = work / Path(data["originalFilename"]).name
    with path.open("wb") as output:
        shutil.copyfileobj(media.file, output)
    jobs[jid] = {"status": "queued", "sttProgress": 0.0, "translationProgress": 0.0,
                 "message": "대기 중", "result": None, "cancelled": False, "work": str(work)}
    background.add_task(run_job, jid, path, data["options"])
    return {"jobID": jid, "accepted": True, "message": "accepted"}

@app.get("/v1/jobs/{jid}")
async def get_job(jid: str, authorization: str | None = Header(default=None)):
    auth(authorization)
    if jid not in jobs: raise HTTPException(404, "job not found")
    job = jobs[jid]
    return {"jobID": jid, **{k: v for k, v in job.items() if k not in ("cancelled", "work")}}

@app.delete("/v1/jobs/{jid}")
async def cancel_job(jid: str, authorization: str | None = Header(default=None)):
    auth(authorization)
    if jid in jobs:
        jobs[jid]["cancelled"] = True
        jobs[jid]["status"] = "cancelled"
        jobs[jid]["message"] = "취소됨"
    return {"ok": True}

async def run_job(jid: str, media: Path, options: dict):
    job = jobs[jid]
    try:
        async with semaphore:
            job.update(status="transcribing", message="STT 모델 준비 중")
            model_name = os.environ.get("WHISPER_MODEL", "large-v3")
            model = await asyncio.to_thread(WhisperModel, model_name, device="auto", compute_type="auto")
            language = options.get("sourceLanguage") or None
            segments, info = await asyncio.to_thread(model.transcribe, str(media), language=language, vad_filter=True)
            raw = list(segments)
            transcripts = []
            for i, seg in enumerate(raw):
                if job["cancelled"]: return
                tid = str(uuid.uuid4())
                transcripts.append({"id": tid, "jobID": jid, "chunkIndex": i, "startTime": seg.start,
                    "endTime": seg.end, "text": seg.text.strip(), "language": info.language,
                    "confidence": None, "cues": [], "qualityStatus": "good", "retryCount": 0, "qualityNotes": []})
                job["sttProgress"] = (i + 1) / max(1, len(raw))
                job["message"] = f"STT {i + 1}/{len(raw)}"
            translations = []
            targets = options.get("targetLanguages", [])
            total = max(1, len(transcripts) * len(targets)); done = 0
            job.update(status="translating", message="LLM 번역 중")
            async with httpx.AsyncClient(timeout=300) as client:
                for target in targets:
                    for transcript in transcripts:
                        if job["cancelled"]: return
                        prompt = f"Translate this subtitle to {target}. Return only the translation:\n{transcript['text']}"
                        response = await client.post(f"{OLLAMA_URL}/api/generate", json={
                            "model": OLLAMA_MODEL, "prompt": prompt, "stream": False})
                        response.raise_for_status()
                        translations.append({"id": str(uuid.uuid4()), "transcriptID": transcript["id"], "jobID": jid,
                            "targetLanguage": target, "modelID": options.get("translationModel", "ollama"),
                            "text": response.json()["response"].strip(), "qualityStatus": "good", "qualityNotes": []})
                        done += 1; job["translationProgress"] = done / total
                        job["message"] = f"번역 {done}/{total}"
            job.update(status="completed", sttProgress=1.0, translationProgress=1.0, message="완료",
                       result={"transcripts": transcripts, "translations": translations})
    except Exception as error:
        job.update(status="failed", message=f"{type(error).__name__}: {error}")
    finally:
        shutil.rmtree(job.get("work", ""), ignore_errors=True)
