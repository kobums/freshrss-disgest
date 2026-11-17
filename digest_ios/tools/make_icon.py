# 앱 아이콘 생성: python3 tools/make_icon.py
#   기본   : 주황 그라데이션 바탕 + 흰 종이 한 장(굵은 제목 줄 하나, 점+줄 셋 = 핵심)
#   다크   : 배경 투명 (iOS가 어두운 배경을 깐다)
#   틴티드 : 회색조, 배경 투명 (iOS가 사용자가 고른 색으로 물들인다)
# 인자 없이 실행하면 세 장을 Assets.xcassets/AppIcon.appiconset 에 쓴다.
# 필요: Pillow
import os
from PIL import Image, ImageDraw, ImageFilter

N = 4096  # 크게 그린 뒤 1024로 줄여 가장자리를 부드럽게
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "Digest", "Resources", "Assets.xcassets", "AppIcon.appiconset")


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def rounded(size, box, radius, fill):
    """box 자리에 둥근 사각형이 칠해진 RGBA 레이어"""
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).rounded_rectangle(box, radius=radius, fill=fill)
    return layer


def make(variant):
    if variant == "light":
        top, bottom = (251, 146, 60), (194, 65, 12)  # 밝은 주황 → 앱 강조색
        canvas = Image.new("RGBA", (N, N))
        d = ImageDraw.Draw(canvas)
        for y in range(N):
            d.line([(0, y), (N, y)], fill=lerp(top, bottom, y / (N - 1)) + (255,))
    else:
        canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    if variant == "tinted":
        paper, title, dot, line = (255, 255, 255), (110, 110, 110), (110, 110, 110), (175, 175, 175)
    elif variant == "dark":
        paper, title, dot, line = (244, 244, 246), (234, 88, 12), (234, 88, 12), (176, 178, 188)
    else:
        paper, title, dot, line = (255, 255, 255), (194, 65, 12), (234, 88, 12), (214, 205, 198)

    # 종이
    pw, ph = int(N * 0.56), int(N * 0.66)
    px, py = (N - pw) // 2, (N - ph) // 2
    box = [px, py, px + pw, py + ph]
    radius = int(N * 0.055)
    if variant == "light":
        shadow = rounded((N, N), [px, py + int(N * 0.02), px + pw, py + ph + int(N * 0.02)], radius, (90, 25, 0, 110))
        canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(N * 0.02)))
    canvas = Image.alpha_composite(canvas, rounded((N, N), box, radius, paper + (255,)))

    d = ImageDraw.Draw(canvas)
    margin = int(N * 0.075)
    left, right = px + margin, px + pw - margin

    # 제목: 굵은 줄 하나
    th = int(N * 0.062)
    ty = py + int(N * 0.095)
    d.rounded_rectangle([left, ty, right, ty + th], radius=th // 2, fill=title + (255,))

    # 핵심: 점 + 줄 셋 (아래로 갈수록 짧게)
    lh = int(N * 0.038)
    r = int(N * 0.024)
    y = ty + th + int(N * 0.115)
    gap = int(N * 0.112)
    line_left = left + r * 2 + int(N * 0.04)
    for width in (1.0, 0.82, 0.6):
        cy = y + lh // 2
        d.ellipse([left, cy - r, left + r * 2, cy + r], fill=dot + (255,))
        d.rounded_rectangle([line_left, y, line_left + int((right - line_left) * width), y + lh],
                            radius=lh // 2, fill=line + (255,))
        y += gap

    icon = canvas.resize((1024, 1024), Image.LANCZOS)
    if variant == "light":
        icon = icon.convert("RGB")  # 기본 아이콘은 알파 없이
    return icon


for variant, name in (("light", "AppIcon-1024.png"), ("dark", "AppIcon-dark.png"), ("tinted", "AppIcon-tinted.png")):
    make(variant).save(os.path.join(OUT, name), "PNG")
    print("wrote", name)
