"""Mixing Console — separa uma música em stems (voz, bateria, baixo...) com Demucs.

Rodar:  .venv\\Scripts\\python.exe server.py   e abrir http://localhost:8000
"""

import json
import os
import queue
import warnings
import re
import shutil
import subprocess
import tempfile
import threading
import time
import types
import uuid
from pathlib import Path

import numpy as np
import soundfile as sf
import uvicorn
from fastapi import FastAPI, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

os.environ.setdefault("HF_HUB_DISABLE_SYMLINKS_WARNING", "1")
warnings.filterwarnings("ignore")

ROOT = Path(__file__).parent
LIBRARY = ROOT / "library"
LIBRARY.mkdir(exist_ok=True)

MODEL_NAME = "htdemucs_6s"  # voz, bateria, baixo, guitarra, piano, outros
WINDS_MODEL = "17_HP-Wind_Inst-UVR.pth"  # tira os sopros (sax, flauta, trompete...) da faixa "outros"
MODELS = ROOT / "models"
MODELS.mkdir(exist_ok=True)
LABELS = {
    "vocals": "Vozes",
    "guitar": "Violão e guitarra",  # o Demucs não distingue um do outro
    "drums": "Bateria",
    "bass": "Baixo",
    "piano": "Teclado",
    "winds": "Sopros",
    "other": "Outros",
}

app = FastAPI()
app.mount("/fonts", StaticFiles(directory=ROOT / "PT_Sans"), name="fonts")
jobs: "queue.Queue[str]" = queue.Queue()
meta_lock = threading.Lock()


# ---------- metadados ----------

def song_dir(song_id: str) -> Path:
    if not re.fullmatch(r"[0-9a-f]{12}", song_id):
        raise HTTPException(404, "Música não encontrada")
    d = LIBRARY / song_id
    if not d.exists():
        raise HTTPException(404, "Música não encontrada")
    return d


def read_meta(song_id: str) -> dict:
    with meta_lock:
        return json.loads((LIBRARY / song_id / "meta.json").read_text("utf-8"))


def write_meta(song_id: str, **changes) -> dict:
    with meta_lock:
        path = LIBRARY / song_id / "meta.json"
        meta = json.loads(path.read_text("utf-8")) if path.exists() else {}
        meta.update(changes)
        path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), "utf-8")
        return meta


# ---------- separação (thread única; o PyTorch já usa todos os núcleos) ----------

_model = None
_winds_model = None
_current_job = None
_progress_span = (0.0, 1.0)  # trecho da barra de progresso que a etapa atual ocupa
DEMUCS_SPAN, WINDS_SPAN = (0.0, 0.5), (0.5, 1.0)


class _ProgressTqdm:
    """Substitui o tqdm dos modelos para reportar o progresso ao front-end."""

    def __init__(self, iterable=None, **_):
        self.items = list(iterable)

    def __iter__(self):
        total, last = len(self.items), 0.0
        lo, hi = _progress_span
        for i, item in enumerate(self.items):
            # laços curtos (pré-processamento) ou instantâneos não mexem na barra
            if _current_job and total >= 20 and time.monotonic() - last > 1:
                last = time.monotonic()
                write_meta(_current_job, progress=round(lo + (hi - lo) * i / total, 3))
            yield item


def get_model():
    global _model
    if _model is None:
        import demucs.apply
        from demucs.pretrained import get_model as load

        demucs.apply.tqdm = types.SimpleNamespace(tqdm=_ProgressTqdm)
        _model = load(MODEL_NAME)
        _model.eval()
    return _model


def get_winds_model(out_dir: Path):
    global _winds_model
    if _winds_model is None:
        import logging

        import audio_separator.separator.architectures.vr_separator as vr
        from audio_separator.separator import Separator

        vr.tqdm = _ProgressTqdm
        _winds_model = Separator(model_file_dir=str(MODELS), output_format="FLAC", log_level=logging.WARNING)
        _winds_model.load_model(WINDS_MODEL)
    _winds_model.output_dir = _winds_model.model_instance.output_dir = str(out_dir)
    return _winds_model


def separate(song_id: str):
    global _current_job, _progress_span
    d = LIBRARY / song_id
    stems_dir = d / "stems"
    if not (stems_dir / "other.flac").exists():
        separate_demucs(song_id)

    # sopros: separados da faixa "outros" do Demucs, que é onde eles caem
    if not (stems_dir / "winds.flac").exists():
        write_meta(song_id, status="separating_winds", progress=WINDS_SPAN[0])
        tmp = Path(tempfile.mkdtemp(dir=d))
        try:
            _current_job, _progress_span = song_id, WINDS_SPAN
            get_winds_model(tmp).separate(str(stems_dir / "other.flac"),
                                          {"Woodwinds": "winds", "No Woodwinds": "other"})
        finally:
            _current_job = None
        (tmp / "other.flac").replace(stems_dir / "other.flac")
        (tmp / "winds.flac").replace(stems_dir / "winds.flac")
        shutil.rmtree(tmp, ignore_errors=True)
        for old in (d / "transposed").glob("other_*.flac"):  # cache feito com a faixa antiga
            old.unlink()

    stems = [s for s in read_meta(song_id).get("stems", []) if s != "winds"] + ["winds"]
    write_meta(song_id, status="done", progress=1, stems=stems)


def separate_demucs(song_id: str):
    global _current_job, _progress_span
    import torch
    from demucs.apply import apply_model
    from demucs.audio import AudioFile

    d = LIBRARY / song_id
    write_meta(song_id, status="loading_model", progress=0)
    model = get_model()

    write_meta(song_id, status="separating")
    source = next(d.glob("original.*"))
    wav = AudioFile(source).read(streams=0, samplerate=model.samplerate, channels=model.audio_channels)
    ref = wav.mean(0)
    mean, std = ref.mean(), ref.std() + 1e-8

    _current_job, _progress_span = song_id, DEMUCS_SPAN
    try:
        with torch.no_grad():
            out = apply_model(model, ((wav - mean) / std)[None], device="cpu",
                              shifts=1, split=True, overlap=0.25, progress=True)[0]
    finally:
        _current_job = None
    out = out * std + mean

    stems_dir = d / "stems"
    stems_dir.mkdir(exist_ok=True)
    for name, audio in zip(model.sources, out):
        sf.write(stems_dir / f"{name}.flac", audio.numpy().T.clip(-1, 1), model.samplerate, subtype="PCM_16")

    write_meta(song_id, stems=list(model.sources), duration=wav.shape[1] / model.samplerate)


def worker():
    while True:
        song_id = jobs.get()
        try:
            separate(song_id)
        except Exception as e:  # noqa: BLE001
            write_meta(song_id, status="error", error=str(e))


# ---------- API ----------

@app.get("/")
def index():
    return FileResponse(ROOT / "index.html")


@app.get("/api/songs")
def list_songs():
    songs = []
    for d in LIBRARY.iterdir():
        if (d / "meta.json").exists():
            songs.append(read_meta(d.name))
    return sorted(songs, key=lambda m: m.get("created", 0), reverse=True)


@app.get("/api/labels")
def labels():
    return LABELS


@app.post("/api/upload")
async def upload(file: UploadFile):
    song_id = uuid.uuid4().hex[:12]
    d = LIBRARY / song_id
    d.mkdir()
    ext = Path(file.filename or "").suffix.lower() or ".mp3"
    with open(d / f"original{ext}", "wb") as f:
        shutil.copyfileobj(file.file, f)
    title = Path(file.filename or "Música").stem
    meta = write_meta(song_id, id=song_id, title=title, status="queued", progress=0, created=time.time())
    jobs.put(song_id)
    return meta


@app.get("/api/songs/{song_id}")
def get_song(song_id: str):
    song_dir(song_id)
    return read_meta(song_id)


@app.delete("/api/songs/{song_id}")
def delete_song(song_id: str):
    d = song_dir(song_id)
    if read_meta(song_id)["status"] not in ("done", "error"):
        raise HTTPException(409, "Aguarde o processamento terminar")
    shutil.rmtree(d)
    return {"ok": True}


# ---------- transposição (Rubber Band via ffmpeg, com cache em disco) ----------

_stem_locks: dict[str, threading.Lock] = {}


def stem_semitones(stem: str, semitones: int, transpose_drums: bool) -> int:
    """Bateria não tem tom definido; por padrão fica como está."""
    return semitones if stem != "drums" or transpose_drums else 0


def stem_path(d: Path, stem: str, semitones: int) -> Path:
    base = d / "stems" / f"{stem}.flac"
    if stem not in LABELS or not base.exists():
        raise HTTPException(404)
    if not -12 <= semitones <= 12:
        raise HTTPException(400, "Transposição deve ficar entre -12 e +12 semitons")
    if semitones == 0:
        return base

    out = d / "transposed" / f"{stem}_{semitones:+d}.flac"
    with meta_lock:
        lock = _stem_locks.setdefault(str(out), threading.Lock())
    with lock:
        if not out.exists():
            out.parent.mkdir(exist_ok=True)
            filt = f"rubberband=pitch={2 ** (semitones / 12)}:pitchq=quality:channels=together"
            if stem == "vocals":
                filt += ":formant=preserved"  # evita voz de "esquilo"/"monstro"
            tmp = out.with_name(out.stem + ".tmp.flac")
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(base), "-af", filt,
                            "-c:a", "flac", "-sample_fmt", "s16", str(tmp)], check=True)
            tmp.replace(out)
    return out


@app.get("/api/songs/{song_id}/stems/{stem}.flac")
def get_stem(song_id: str, stem: str, semitones: int = 0):
    return FileResponse(stem_path(song_dir(song_id), stem, semitones), media_type="audio/flac")


class ExportRequest(BaseModel):
    gains: dict[str, float]  # stem -> volume (0 = removido)
    format: str = "mp3"
    semitones: int = 0
    transpose_drums: bool = False


@app.post("/api/songs/{song_id}/export")
def export(song_id: str, req: ExportRequest):
    d = song_dir(song_id)
    meta = read_meta(song_id)
    if meta["status"] != "done":
        raise HTTPException(409, "A música ainda não foi separada")

    mix, sr = None, None
    length = sf.info(d / "stems" / f"{meta['stems'][0]}.flac").frames
    for stem in meta["stems"]:
        gain = max(0.0, min(2.0, req.gains.get(stem, 1.0)))
        if gain == 0:
            continue
        path = stem_path(d, stem, stem_semitones(stem, req.semitones, req.transpose_drums))
        audio, sr = sf.read(path, dtype="float32")
        audio = np.pad(audio[:length], ((0, max(0, length - len(audio))), (0, 0)))  # transposição pode mudar o tamanho
        mix = audio * gain if mix is None else mix + audio * gain
    if mix is None:
        raise HTTPException(400, "Todos os instrumentos estão desligados")
    peak = np.abs(mix).max()
    if peak > 0.99:
        mix *= 0.99 / peak

    removed = [LABELS[s].lower() for s in meta["stems"] if req.gains.get(s, 1.0) == 0]
    kept = [LABELS[s].lower() for s in meta["stems"] if req.gains.get(s, 1.0) > 0]
    if len(kept) == 1:
        suffix = f" (só {kept[0]})"
    elif removed:
        suffix = f" (sem {', '.join(removed)})"
    else:
        suffix = " (mix)" if not req.semitones else ""
    if req.semitones:
        suffix += f" [{req.semitones:+d} {'semitom' if abs(req.semitones) == 1 else 'semitons'}]"
    name =re.sub(r'[\\/:*?"<>|]', "_", meta["title"] + suffix)

    tmp = Path(tempfile.mkdtemp())
    wav_path = tmp / "mix.wav"
    sf.write(wav_path, mix, sr, subtype="PCM_16")
    if req.format == "wav":
        return FileResponse(wav_path, filename=f"{name}.wav", media_type="audio/wav")
    mp3_path = tmp / "mix.mp3"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav_path), "-b:a", "320k", str(mp3_path)],
                   check=True)
    return FileResponse(mp3_path, filename=f"{name}.mp3", media_type="audio/mpeg")


def resume_pending():
    for d in LIBRARY.iterdir():
        if not (d / "meta.json").exists():
            continue
        meta = read_meta(d.name)
        # músicas separadas antes de existir a faixa de sopros também entram na fila
        if meta["status"] not in ("done", "error") or meta["status"] == "done" and "winds" not in meta["stems"]:
            write_meta(d.name, status="queued", progress=0)
            jobs.put(d.name)


def server_running() -> bool:
    import socket

    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", 8000)) == 0


def open_browser_when_ready():
    import webbrowser

    while not server_running():
        time.sleep(0.2)
    webbrowser.open("http://localhost:8000")


if __name__ == "__main__":
    if server_running():  # já aberto (ex.: clicou duas vezes no atalho): só mostra de novo
        open_browser_when_ready()
        raise SystemExit
    threading.Thread(target=open_browser_when_ready, daemon=True).start()
    resume_pending()
    threading.Thread(target=worker, daemon=True).start()
    print("\n  Mixing Console rodando em  http://localhost:8000\n")
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="warning")
