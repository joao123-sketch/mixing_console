# Mixing Console

Separa uma música em faixas — **vozes, bateria, baixo, violão/guitarra, teclado, sopros e outros** — com inteligência artificial (Demucs + UVR), e deixa você aumentar, abaixar ou tirar cada instrumento, mudar o tom e exportar o resultado em MP3 ou WAV.

Tudo roda no seu computador: nenhuma música é enviada para a internet.

## Como instalar (Windows 10 ou 11, 64 bits)

1. Nesta página, clique no botão verde **`<> Code`** e depois em **`Download ZIP`**.
2. Abra a pasta Downloads, clique com o botão direito em `mixing_console-main.zip` e escolha **Extrair tudo...**
3. Entre na pasta extraída e dê dois cliques em **`INSTALAR.bat`**.
   - Se aparecer *"O Windows protegeu o computador"*, clique em **Mais informações** → **Executar assim mesmo**.
4. Leia as informações da tela e pressione **ENTER**. O instalador mostra cada passo: o que está baixando, por que, o tamanho e quanto tempo deve levar.
5. No fim, aparece o atalho **Mixing Console** na Área de Trabalho.

Depois de instalado, a pasta extraída e o .zip podem ser apagados.

### O que o instalador baixa

| O quê | Tamanho | Para quê |
|---|---|---|
| Python 3.11 (versão portátil oficial) | ~17 MB | a linguagem em que o programa é feito |
| FFmpeg | ~115 MB | ler/gravar MP3 e mudar o tom |
| Bibliotecas (PyTorch, Demucs, Audio Separator...) | ~380 MB | o motor de inteligência artificial |
| Modelos de IA treinados (Demucs htdemucs_6s + UVR sopros) | ~280 MB | o que reconhece cada instrumento |
| Visual C++ da Microsoft (só se faltar) | ~25 MB | exigido pelo PyTorch; pede permissão de administrador |

Total: **~800 MB de download e ~3 GB em disco**. Leva de 10 a 20 minutos numa internet de 50 Mbps.

Tudo fica em `%LOCALAPPDATA%\MixingConsole` — nada é instalado no resto do sistema, e um Python que já exista no computador não é afetado.

## Como usar

1. Dois cliques no atalho **Mixing Console**.
2. Uma janela preta abre (é o programa rodando — deixe-a aberta; fechá-la desliga o Mixing Console) e o navegador abre em `http://localhost:8000`.
3. Arraste uma música para a tela. A separação usa só o processador, então leva alguns minutos por música.

## Desinstalar

Abra `%LOCALAPPDATA%\MixingConsole` (cole isso na barra de endereço do Explorador de Arquivos) e dê dois cliques em `desinstalar.bat`.

## Problemas

- **A instalação parou com erro:** rode o `INSTALAR.bat` de novo — o que já foi baixado é aproveitado. O registro completo fica em `%LOCALAPPDATA%\MixingConsole\instalacao.log`.
- **O navegador não abriu:** abra `http://localhost:8000` manualmente com a janela preta aberta.
