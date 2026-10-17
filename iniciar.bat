@echo off
title Mixing Console (feche esta janela para desligar)
cd /d "%~dp0"
if exist "python\python.exe" (
    rem instalado pelo INSTALAR.bat: Python, ffmpeg e modelos ficam dentro desta pasta
    set "PATH=%~dp0ffmpeg\bin;%PATH%"
    set "TORCH_HOME=%~dp0models\torch"
    set "HF_HOME=%~dp0models\huggingface"
    set "HF_HUB_VERBOSITY=error"
    set "PYTHONNOUSERSITE=1"
    python\python.exe server.py
) else (
    .venv\Scripts\python.exe server.py
)
if errorlevel 1 pause
