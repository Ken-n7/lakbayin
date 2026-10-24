"""How to Play's pictures: stages the match moments in offline Practice
(guide_moments.tscn), then crops each to its subject into assets/ui/guide/.
Run from the repo root:  python3 game/tools/guide_shots.py"""
import os, subprocess, sys, tempfile
from pathlib import Path
from PIL import Image

GAME = Path(__file__).resolve().parents[1]
OUT = GAME / 'assets/ui/guide'
WIDTH = 420     # 3x the ~140px the guide shows them at
# name: (left, top, right, bottom) on the 1920x1080 shot
CROPS = {
    'monk': (480, 290, 1840, 970),
    'keypad': (45, 150, 1875, 930),
    'locked': (45, 150, 1875, 930),
    'answered': (520, 300, 1880, 980),
    'typing': (480, 260, 1840, 940),
    'deposit': (520, 160, 1880, 1000),
    'clock': (560, 0, 1920, 135),
    'minimap': (0, 0, 450, 255),
}

with tempfile.TemporaryDirectory() as tmp:
    env = {**os.environ, 'LAKBAYIN_SERVER_URL': 'https://offline.invalid'}
    subprocess.run(['godot', '--path', str(GAME), 'res://tools/guide_moments.tscn', '--', tmp],
                   env=env, check=True, timeout=180)
    OUT.mkdir(parents=True, exist_ok=True)
    for name, box in CROPS.items():
        im = Image.open(Path(tmp) / f'{name}.png').convert('RGB').crop(box)
        im = im.resize((WIDTH, round(im.height * WIDTH / im.width)), Image.LANCZOS)
        im.save(OUT / f'{name}.png', optimize=True)
        print(name, im.size)
