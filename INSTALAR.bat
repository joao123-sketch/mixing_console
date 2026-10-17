@echo off
chcp 65001 >nul
title Instalador do Mixing Console
cd /d "%~dp0"
if not exist "instalador\instalar.ps1" (
    echo.
    echo   Nao encontrei os arquivos do instalador.
    echo   Se voce abriu o INSTALAR.bat de dentro do arquivo .zip, primeiro extraia a pasta:
    echo   clique com o botao direito no .zip ^> "Extrair tudo...", e rode o INSTALAR.bat
    echo   que fica dentro da pasta extraida.
    echo.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0instalador\instalar.ps1" %*
echo.
pause
