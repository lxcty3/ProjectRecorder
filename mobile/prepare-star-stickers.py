"""Generate the 16 star companion sticker assets used by the mobile UI.

Source files are the supplied 2048px stickers. We keep a full sticker version
for the hero rail and a face crop for small chat/status avatars. Both lose the
white backdrop and are compressed to WebP so the APK stays small.
"""
import importlib.util
import os
from pathlib import Path
from PIL import Image, ImageOps

HERE = Path(__file__).resolve().parent
SOURCE = Path(r"D:\戮秀\16\16")
OUT = HERE / "icons" / "star"
PREP = HERE / "prepare-avatars.py"

spec = importlib.util.spec_from_file_location("avatar_prep", PREP)
avatar_prep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(avatar_prep)

STARS = [
    ("star_01_hug", "表情包16_01_抱抱.png", "抱抱", "先接住自己，再处理事情。"),
    ("star_02_roger", "表情包16_02_收到.png", "收到", "收到，我来把这件事落到下一步。"),
    ("star_03_tea", "表情包16_03_喝茶.png", "喝茶", "缓一口气，节奏比速度重要。"),
    ("star_04_work", "表情包16_04_工作中.png", "工作中", "进入专注轨道，先完成最小的一步。"),
    ("star_05_wow", "表情包16_05_惊讶.png", "惊讶", "有变化就先核对，不急着下结论。"),
    ("star_06_hmph", "表情包16_06_哼.png", "哼", "可以不同意，但把理由写清楚。"),
    ("star_07_sleep", "表情包16_07_睡觉.png", "睡觉", "今天到这里，休息也是进度。"),
    ("star_08_great", "表情包16_08_太好了.png", "太好了", "一切在变好，继续保持现在的节奏。"),
    ("star_09_music", "表情包16_09_听歌.png", "听歌", "给自己一段不被打断的时间。"),
    ("star_10_read", "表情包16_10_看书.png", "看书", "先找依据，再决定下一步。"),
    ("star_11_yum", "表情包16_11_好吃.png", "好吃", "补充能量，才有力气继续。"),
    ("star_12_meow", "表情包16_12_喵.png", "喵", "允许自己可爱一点，也允许事情慢一点。"),
    ("star_13_out", "表情包16_13_想出去.png", "想出去", "想离开一下没关系，回来再继续。"),
    ("star_14_what", "表情包16_14_疑惑.png", "疑惑", "没想清楚就先标记问题，不用硬猜。"),
    ("star_15_tired", "表情包16_15_好累.png", "好累", "累不是失败，今天只做必要的事。"),
    ("star_16_bye", "表情包16_16_下次见.png", "下次见", "收好今天的进度，下次接着来。"),
]

CROPS = {
    "star_01_hug": (0.26, 0.24, 0.84, 0.82),
    "star_07_sleep": (0.17, 0.34, 0.84, 0.90),
    "star_13_out": (0.17, 0.30, 0.83, 0.90),
    "star_15_tired": (0.17, 0.36, 0.84, 0.92),
    "star_16_bye": (0.12, 0.18, 0.86, 0.86),
}
DEFAULT_CROP = (0.18, 0.22, 0.84, 0.86)

def padded_contain(image, size, pad=0.035):
    bbox = image.getchannel("A").getbbox()
    if bbox:
        image = image.crop(bbox)
    inner = int(size * (1 - pad * 2))
    image.thumbnail((inner, inner), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(image, ((size-image.width)//2, (size-image.height)//2))
    return canvas

OUT.mkdir(parents=True, exist_ok=True)
for key, filename, label, message in STARS:
    src = Image.open(SOURCE / filename).convert("RGB")
    src = src.resize((768, 768), Image.Resampling.LANCZOS)
    cut = avatar_prep.cut_white_background(src, blend=0.0)
    full = padded_contain(cut, 512, pad=0.018)
    full.save(OUT / f"{key}.webp", "WEBP", quality=88, method=6)
    left, top, right, bottom = CROPS.get(key, DEFAULT_CROP)
    face = cut.crop((int(left*768), int(top*768), int(right*768), int(bottom*768)))
    face = padded_contain(face, 192, pad=0.02)
    face.save(OUT / f"{key}@face.webp", "WEBP", quality=88, method=6)
    print(key, full.width, face.width)
print("generated", len(STARS), "star sticker pairs")
