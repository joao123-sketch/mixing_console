# Instalador do Mixing Console.
# Baixa tudo o que o programa precisa para dentro de uma única pasta (sem mexer no resto do
# computador) e cria o atalho na Área de Trabalho. Pode ser rodado de novo sem problema: o que
# já estiver instalado é pulado, e as músicas já separadas são mantidas.

param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "MixingConsole"),
    [switch]$SemAtalho,    # para testes: não cria atalhos
    [switch]$SemPerguntas  # não espera ENTER no início nem pergunta se quer abrir no fim
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # a barra do Invoke-WebRequest deixa o download 10x mais lento
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Source = Split-Path $PSScriptRoot -Parent
$PythonUrl = "https://www.nuget.org/api/v2/package/python/3.11.9"
$FfmpegUrls = @(
    "https://github.com/GyanD/codexffmpeg/releases/download/9.0.2/ffmpeg-9.0.2-essentials_build.zip",
    "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
)
$VcRedistUrl = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
$TotalSteps = 6

# O Windows limita caminhos a 260 caracteres e o PyTorch tem arquivos com ~130 caracteres dentro
# de site-packages. Com nomes de usuário longos, usa uma pasta mais curta.
$longPaths = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -ErrorAction SilentlyContinue).LongPathsEnabled -eq 1
if (-not $longPaths -and (Join-Path $InstallDir "python\Lib\site-packages").Length + 135 -ge 260) {
    $InstallDir = Join-Path $env:SystemDrive "MixingConsole"
}
$Started = Get-Date
$script:BytesPerSec = 0  # medido no primeiro download, usado para estimar os seguintes

# ---------- aparência ----------

function Write-Title($text) {
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkMagenta
    Write-Host "  $text" -ForegroundColor Magenta
    Write-Host ("=" * 72) -ForegroundColor DarkMagenta
}

function Write-Step($n, $title, $what, $why, $size, $mb, $extraSec = 0) {
    Write-Host ""
    Write-Host ("-" * 72) -ForegroundColor DarkCyan
    Write-Host "  PASSO $n de $TotalSteps  |  $title" -ForegroundColor Cyan
    Write-Host ("-" * 72) -ForegroundColor DarkCyan
    Write-Host "  O que é:        " -NoNewline -ForegroundColor DarkGray; Write-Host $what
    Write-Host "  Por que:        " -NoNewline -ForegroundColor DarkGray; Write-Host $why
    Write-Host "  Download:       " -NoNewline -ForegroundColor DarkGray; Write-Host $size
    Write-Host "  Tempo estimado: " -NoNewline -ForegroundColor DarkGray; Write-Host (Get-Estimate $mb $extraSec)
    Write-Host ""
}

function Write-Ok($text) { Write-Host "  [OK] $text" -ForegroundColor Green }
function Write-Info($text) { Write-Host "  $text" -ForegroundColor Gray }

function Format-Duration([double]$sec) {
    if ($sec -lt 60) { return "{0:0} s" -f [Math]::Max(1, $sec) }
    $m = [Math]::Floor($sec / 60); $s = [Math]::Round($sec % 60)
    if ($m -lt 60) { return "{0} min {1:00} s" -f $m, $s }
    return "{0} h {1:00} min" -f [Math]::Floor($m / 60), ($m % 60)
}

function Get-Estimate($mb, $extraSec) {
    if ($mb -le 0) { return "~" + (Format-Duration $extraSec) }
    if ($script:BytesPerSec -gt 0) {
        $sec = $mb * 1MB / $script:BytesPerSec + $extraSec
        $mbps = $script:BytesPerSec * 8 / 1e6
        return "~{0} (sua conexão mediu ~{1:0.0} Mbps)" -f (Format-Duration $sec), $mbps
    }
    # ainda sem medição: mostra a faixa típica
    $fast = $mb * 8 / 100 + $extraSec; $slow = $mb * 8 / 10 + $extraSec
    return "entre {0} (internet de 100 Mbps) e {1} (10 Mbps)" -f (Format-Duration $fast), (Format-Duration $slow)
}

function Expand-Zip($zip, $dest) {
    Write-Info "Descompactando..."
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Force $dest | Out-Null
    # o tar do Windows 10/11 é bem mais rápido que o Expand-Archive
    $tar = Join-Path $env:windir "System32\tar.exe"
    if (Test-Path $tar) {
        & $tar -xf $zip -C $dest
        if ($LASTEXITCODE -eq 0) { return }
    }
    Expand-Archive $zip $dest -Force
}

function Step-Done($stepStart) {
    $took = (Get-Date) - $stepStart
    Write-Ok ("Passo concluído em {0}  (tempo total até agora: {1})" -f (Format-Duration $took.TotalSeconds), (Format-Duration ((Get-Date) - $Started).TotalSeconds))
}

function Fail($text) {
    Write-Host ""
    Write-Host "  [ERRO] $text" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Dicas: confira a conexão com a internet e rode o INSTALAR.bat de novo;" -ForegroundColor Yellow
    Write-Host "  o que já foi baixado não será baixado outra vez." -ForegroundColor Yellow
    Write-Host "  Registro completo da instalação: $InstallDir\instalacao.log" -ForegroundColor Yellow
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

# ---------- download com barra de progresso ----------

function Get-File($urls, $dest) {
    foreach ($url in @($urls)) {
        Write-Info "Baixando de: $url"
        $t0 = Get-Date
        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        try {
            if ($curl) {
                # curl.exe vem com o Windows 10/11 e mostra uma barra de progresso
                & $curl.Source -L --fail --retry 3 --retry-delay 3 --progress-bar -o $dest $url
                if ($LASTEXITCODE -ne 0) { throw "curl terminou com código $LASTEXITCODE" }
            } else {
                Write-Info "(baixando... este computador não tem curl, então não há barra de progresso)"
                Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
            }
        } catch {
            Write-Host "  Falhou ($_). " -ForegroundColor Yellow -NoNewline
            if ($url -ne @($urls)[-1]) { Write-Host "Tentando endereço alternativo..." -ForegroundColor Yellow }
            continue
        }
        $sec = ((Get-Date) - $t0).TotalSeconds
        $bytes = (Get-Item $dest).Length
        if ($sec -gt 0.5) { $script:BytesPerSec = $bytes / $sec }
        Write-Ok ("Baixado: {0:0.0} MB em {1}" -f ($bytes / 1MB), (Format-Duration $sec))
        return
    }
    Fail "Não foi possível baixar $dest"
}

# ---------- início ----------

Write-Title "Instalador do Mixing Console"
Write-Host @"

  O Mixing Console separa uma música em faixas (voz, bateria, baixo, violão/guitarra,
  teclado, sopros e outros) usando inteligência artificial, e deixa você aumentar,
  abaixar ou tirar cada instrumento e mudar o tom da música.

  Ele roda inteiramente no seu computador (nenhuma música é enviada para a internet),
  mas para isso precisa de algumas ferramentas que este instalador vai baixar:

    O QUE                                   TAMANHO      PARA QUÊ
    Python 3.11                              ~17 MB      linguagem em que o programa é feito
    FFmpeg                                  ~115 MB      ler/gravar MP3 e mudar o tom
    Bibliotecas (PyTorch, Demucs etc.)      ~380 MB      o "motor" de inteligência artificial
    Modelos de IA treinados                 ~280 MB      o "cérebro" que reconhece os instrumentos
    Visual C++ da Microsoft (se faltar)      ~25 MB      peça do Windows exigida pelo PyTorch
                                           ---------
                                           ~800 MB de download, ~3 GB de espaço em disco

  Tempo total estimado: de 10 a 20 minutos numa internet de 50 Mbps;
  pode passar de 30 minutos em conexões mais lentas. Não feche esta janela.

  Tudo será instalado em:  $InstallDir
  (nada é instalado no resto do sistema; para remover, use o "desinstalar.bat" dessa pasta)

"@
if (-not $SemPerguntas) {
    Write-Host "  Pressione ENTER para começar, ou feche esta janela para cancelar." -ForegroundColor Yellow
    [void](Read-Host)
}

New-Item -ItemType Directory -Force $InstallDir | Out-Null
Start-Transcript -Path (Join-Path $InstallDir "instalacao.log") -Append | Out-Null
$Downloads = Join-Path $InstallDir "_downloads"
New-Item -ItemType Directory -Force $Downloads | Out-Null

# ---------- passo 1: verificações ----------

$t = Get-Date
Write-Step 1 "Verificando o computador" `
    "Checagem do Windows, do espaço em disco e da conexão." `
    "Evita começar a baixar ~800 MB e descobrir no meio que não vai dar certo." `
    "nada" 0 5

if (-not [Environment]::Is64BitOperatingSystem) { Fail "O Mixing Console precisa de um Windows de 64 bits." }
Write-Ok "Windows de 64 bits"

$drive = (Get-Item $InstallDir).PSDrive
$freeGB = [Math]::Round($drive.Free / 1GB, 1)
if ($freeGB -lt 4) { Fail "Pouco espaço no disco ${drive}: ($freeGB GB livres; são necessários pelo menos 4 GB)." }
Write-Ok "Espaço livre no disco ${drive}: $freeGB GB"

try {
    Invoke-WebRequest -Uri "https://pypi.org" -Method Head -UseBasicParsing -TimeoutSec 15 | Out-Null
    Write-Ok "Conexão com a internet"
} catch { Fail "Sem acesso à internet (não consegui acessar pypi.org)." }

$needVc = -not ((Test-Path "$env:windir\System32\msvcp140.dll") -and (Test-Path "$env:windir\System32\vcruntime140_1.dll"))
Step-Done $t

# ---------- passo 2: Visual C++ ----------

$t = Get-Date
Write-Step 2 "Componentes Visual C++ da Microsoft" `
    "Bibliotecas oficiais da Microsoft que muitos programas usam (Microsoft Visual C++ Redistributable)." `
    "O PyTorch, motor de IA do Mixing Console, não abre sem elas." `
    $(if ($needVc) { "~25 MB" } else { "nada (já instalado neste computador)" }) $(if ($needVc) { 25 } else { 0 }) $(if ($needVc) { 60 } else { 1 })
if ($needVc) {
    $vc = Join-Path $Downloads "vc_redist.x64.exe"
    Get-File $VcRedistUrl $vc
    Write-Host "  O Windows vai pedir permissão de administrador para instalar este componente." -ForegroundColor Yellow
    Write-Host "  Clique em 'Sim' na janela que aparecer." -ForegroundColor Yellow
    try {
        $p = Start-Process $vc -ArgumentList "/install", "/passive", "/norestart" -Verb RunAs -Wait -PassThru
    } catch { Fail "A permissão de administrador foi negada; sem ela o Visual C++ não pode ser instalado." }
    # 1638 = já existe versão mais nova; 3010 = precisa reiniciar (funciona mesmo assim)
    if ($p.ExitCode -notin 0, 1638, 3010) { Fail "A instalação do Visual C++ falhou (código $($p.ExitCode))." }
    Write-Ok "Visual C++ instalado"
} else {
    Write-Ok "Já está instalado, nada a fazer"
}
Step-Done $t

# ---------- passo 3: Python ----------

$t = Get-Date
$Python = Join-Path $InstallDir "python\python.exe"
$pyDone = Test-Path $Python
Write-Step 3 "Python 3.11" `
    "A linguagem de programação em que o Mixing Console foi escrito (versão portátil oficial)." `
    "Sem ele o programa não roda. Fica só dentro da pasta do Mixing Console; não interfere em outro Python." `
    $(if ($pyDone) { "nada (já baixado)" } else { "~17 MB" }) $(if ($pyDone) { 0 } else { 17 }) 15
if (-not $pyDone) {
    $zip = Join-Path $Downloads "python.zip"
    Get-File $PythonUrl $zip
    $tmp = Join-Path $Downloads "python_tmp"
    Expand-Zip $zip $tmp
    Move-Item (Join-Path $tmp "tools") (Join-Path $InstallDir "python")
    Remove-Item -Recurse -Force $tmp
}
$env:PYTHONNOUSERSITE = "1"  # ignora pacotes de outro Python que o computador já tenha
& $Python --version
if ($LASTEXITCODE -ne 0) { Fail "O Python baixado não funcionou." }
Write-Ok "Python pronto"
Step-Done $t

# ---------- passo 4: FFmpeg ----------

$t = Get-Date
$Ffmpeg = Join-Path $InstallDir "ffmpeg\bin\ffmpeg.exe"
$ffDone = Test-Path $Ffmpeg
Write-Step 4 "FFmpeg" `
    "Ferramenta gratuita de áudio e vídeo, usada no mundo todo." `
    "Lê as músicas (MP3, WAV, M4A...), salva o resultado em MP3 e faz a mudança de tom." `
    $(if ($ffDone) { "nada (já baixado)" } else { "~115 MB" }) $(if ($ffDone) { 0 } else { 115 }) 20
if (-not $ffDone) {
    $zip = Join-Path $Downloads "ffmpeg.zip"
    Get-File $FfmpegUrls $zip
    $tmp = Join-Path $Downloads "ffmpeg_tmp"
    Expand-Zip $zip $tmp
    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
    New-Item -ItemType Directory -Force (Join-Path $InstallDir "ffmpeg") | Out-Null
    Move-Item (Join-Path $inner.FullName "bin") (Join-Path $InstallDir "ffmpeg\bin")
    Remove-Item -Recurse -Force $tmp
}
$ffVersion = & $Ffmpeg -hide_banner -version
if ($LASTEXITCODE -ne 0) { Fail "O FFmpeg baixado não funcionou." }
Write-Info $ffVersion[0]
Write-Ok "FFmpeg pronto"
Step-Done $t

# ---------- arquivos do programa ----------

Write-Info ""
Write-Info "Copiando os arquivos do Mixing Console para $InstallDir ..."
$appItems = "server.py", "index.html", "iniciar.bat", "icone.ico", "icone.png", "gerar_icone.py",
            "requirements.txt", "PT_Sans", "instalador", "INSTALAR.bat", "README.md"
foreach ($item in $appItems) {
    $src = Join-Path $Source $item
    if (-not (Test-Path $src)) { continue }
    if ($src -eq (Join-Path $InstallDir $item)) { continue }  # rodando de dentro da pasta instalada
    Copy-Item $src $InstallDir -Recurse -Force
}
# arquivos vindos de um .zip da internet ficam "bloqueados" pelo Windows
$appItems | ForEach-Object { Join-Path $InstallDir $_ } | Where-Object { Test-Path $_ } |
    Get-ChildItem -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
Set-Content (Join-Path $InstallDir "desinstalar.bat") -Encoding Ascii -Value @"
@echo off
title Desinstalar o Mixing Console
echo.
echo   Isto vai apagar o Mixing Console, as musicas ja separadas e os atalhos.
echo   Pasta: %~dp0
echo.
choice /c SN /m "  Deseja continuar"
if errorlevel 2 exit /b
powershell -NoProfile -Command "Get-Process python* -EA 0 | ? Path -like '%~dp0*' | Stop-Process -Force"
del "%USERPROFILE%\Desktop\Mixing Console.lnk" 2>nul
for /f "usebackq delims=" %%d in (``powershell -NoProfile -Command "[Environment]::GetFolderPath('Desktop')"``) do del "%%d\Mixing Console.lnk" 2>nul
del "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Mixing Console.lnk" 2>nul
cd /d "%TEMP%"
echo   Removendo arquivos...
rmdir /s /q "%~dp0"
"@
Write-Ok "Arquivos copiados"

# ---------- passo 5: bibliotecas ----------

$t = Get-Date
Write-Step 5 "Bibliotecas de inteligência artificial" `
    "86 pacotes: PyTorch (motor de IA, o maior deles: ~205 MB), Demucs e Audio Separator (separação de instrumentos), FastAPI (a tela do programa) e outros." `
    "São o que de fato separa a música em faixas. As versões são exatamente as testadas pelo autor." `
    "~380 MB" 380 120
Write-Info "Você vai ver a lista de pacotes passando; os maiores mostram uma barra de progresso."
Write-Info ""
$pipStart = Get-Date
& $Python -m pip install --disable-pip-version-check --no-warn-script-location --only-binary=:all: `
    -r (Join-Path $InstallDir "requirements.txt")
if ($LASTEXITCODE -ne 0) { Fail "A instalação das bibliotecas falhou (veja as mensagens acima)." }
$pipSec = ((Get-Date) - $pipStart).TotalSeconds
if ($pipSec -gt 60 -and $script:BytesPerSec -eq 0) { $script:BytesPerSec = 380MB / $pipSec }
Write-Ok "Bibliotecas instaladas"
Step-Done $t

# ---------- passo 6: modelos ----------

$t = Get-Date
$env:TORCH_HOME = Join-Path $InstallDir "models\torch"
$env:HF_HOME = Join-Path $InstallDir "models\huggingface"
$env:HF_HUB_VERBOSITY = "error"  # esconde um aviso inofensivo sobre login no Hugging Face
$env:PATH = (Join-Path $InstallDir "ffmpeg\bin") + ";" + $env:PATH
Write-Step 6 "Modelos de IA treinados" `
    "Dois 'cérebros' já treinados: o Demucs (Meta/Facebook), que separa voz, bateria, baixo, violão e teclado, e o UVR, que separa os sopros." `
    "Baixados agora para a primeira música não ter que esperar. Depois disso o programa funciona até sem internet." `
    "~280 MB" 280 30
& $Python (Join-Path $InstallDir "instalador\preparar_modelos.py")
if ($LASTEXITCODE -ne 0) { Fail "O download dos modelos de IA falhou." }
Write-Ok "Modelos prontos"
Step-Done $t

# ---------- atalhos ----------

if (-not $SemAtalho) {
    $shell = New-Object -ComObject WScript.Shell
    $targets = @(
        [Environment]::GetFolderPath("Desktop"),
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs")
    )
    foreach ($dir in $targets) {
        $lnk = $shell.CreateShortcut((Join-Path $dir "Mixing Console.lnk"))
        $lnk.TargetPath = Join-Path $InstallDir "iniciar.bat"
        $lnk.WorkingDirectory = $InstallDir
        $lnk.IconLocation = Join-Path $InstallDir "icone.ico"
        $lnk.Description = "Separa músicas em faixas de instrumentos"
        $lnk.Save()
    }
    Write-Ok "Atalho 'Mixing Console' criado na Área de Trabalho e no Menu Iniciar"
}

Remove-Item -Recurse -Force $Downloads -ErrorAction SilentlyContinue

Write-Title ("Instalação concluída em {0}!" -f (Format-Duration ((Get-Date) - $Started).TotalSeconds))
Write-Host @"

  Como usar:
    1. Dê dois cliques no atalho "Mixing Console" da Área de Trabalho.
    2. Uma janela preta vai abrir (é o programa rodando - deixe-a aberta;
       fechá-la desliga o Mixing Console) e o navegador abre sozinho.
    3. Arraste uma música para a tela. A separação usa só o processador,
       então leva alguns minutos por música (de 3 a 10, dependendo do PC).

"@
try { Stop-Transcript | Out-Null } catch {}

if (-not $SemPerguntas) {
    $ans = Read-Host "  Deseja abrir o Mixing Console agora? (S/N)"
    if ($ans -match "^[sS]") { Start-Process (Join-Path $InstallDir "iniciar.bat") -WorkingDirectory $InstallDir }
}
