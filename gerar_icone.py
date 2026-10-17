"""Desenha o ícone do atalho (uma mesinha de som) e salva em icone.ico.

Rodar:  .venv\\Scripts\\python.exe gerar_icone.py
"""

from pathlib import Path

from PIL import Image, ImageDraw

S = 1024  # desenha grande e reduz, para ficar com bordas suaves
A1, A2 = (139, 92, 255), (255, 77, 141)  # mesmas cores do app
CHANNELS = [  # cor do canal (igual aos pads) e altura do fader (0 = embaixo, 1 = em cima)
    ((255, 77, 141), .70), ((178, 107, 255), .35), ((46, 230, 166), .55),
    ((255, 159, 28), .80), ((61, 184, 255), .45),
]


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def main():
    img = Image.new("RGBA", (S, S))

    # moldura em degradê roxo → rosa
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    for i in range(S * 2):
        gd.line([(i, 0), (0, i)], fill=lerp(A1, A2, i / (S * 2)) + (255,), width=2)
    mask = Image.new("L", (S, S))
    ImageDraw.Draw(mask).rounded_rectangle([40, 120, S - 40, S - 120], radius=110, fill=255)
    img.paste(grad, mask=mask)

    d = ImageDraw.Draw(img)
    d.rounded_rectangle([80, 160, S - 80, S - 160], radius=80, fill=(16, 15, 28))  # tampo da mesa

    left, right = 150, S - 150
    step = (right - left) / len(CHANNELS)
    top, bottom = 300, S - 240
    for i, (color, level) in enumerate(CHANNELS):
        cx = left + step * (i + .5)
        # botão giratório no alto do canal
        d.ellipse([cx - 34, 205, cx + 34, 273], fill=(52, 50, 72))
        d.line([cx, 215, cx + 22 * (level - .5) * 2, 235], fill=color, width=12)
        # trilho com a parte "ativa" acesa
        knob_y = bottom - (bottom - top) * level
        d.rounded_rectangle([cx - 9, top, cx + 9, bottom], radius=9, fill=(52, 50, 72))
        d.rounded_rectangle([cx - 9, knob_y, cx + 9, bottom], radius=9, fill=color)
        # cursor do fader
        d.rounded_rectangle([cx - 46, knob_y - 26, cx + 46, knob_y + 26], radius=14, fill=(243, 241, 250))
        d.line([cx - 30, knob_y, cx + 30, knob_y], fill=(16, 15, 28), width=8)

    out = Path(__file__).parent / "icone.ico"
    img.save(out, sizes=[(n, n) for n in (16, 24, 32, 48, 64, 128, 256)])
    img.resize((256, 256), Image.LANCZOS).save(out.with_suffix(".png"))
    print("salvo em", out)


if __name__ == "__main__":
    main()
