#!/usr/bin/env python3
"""Tiny Swords' ramp with room to step on and off it (client, 2026-10-01: the
ladders "2 wide not 1"). A ramp is walked on and off from the side -- east
and west -- so it keeps the pack's width that way, one cell, and gains a row
north-south: the pack's slanted top, a middle row, and the pack's foot.

Nothing is drawn. The middle row is the pack's own ramp: a band of its foot
(open side and grass) with its top's grass where the foot has rock, laid
twice; every join -- top to band, band to band, band to foot, foot's grass
to top's -- is cut along the line where the two pieces' pixels agree best
(a minimum-error seam), so no straight join shows in the bushes.

One 64x192 ramp per level colour, high ground to its right; the game
mirrors it for the other side (`Art.tall_ramps`). Idempotent. Run from game/:

    python3 tools/make_tall_ramp.py
"""
from PIL import Image

SHEETS = "assets/terrain/tileset/Tilemap_color%d.png"
OUT = "assets/terrain/tileset/TallRamp_color%d.png"
COLORS = [1, 2, 3, 5]
T = 64


def diff(a,b):
    if a[3]==0 and b[3]==0: return 0
    if (a[3]==0)!=(b[3]==0): return 600
    return sum((a[i]-b[i])**2 for i in range(3))**0.5
def hcut(over, under, rows):
    """Where `under` takes over from `over` down an overlap `rows` tall: per
    column, the row of least difference, moving at most one row a column."""
    W=len(over[0]); cost=[[diff(over[y][x],under[y][x]) for x in range(W)] for y in range(rows)]
    acc=[[0]*W for _ in range(rows)]; back=[[0]*W for _ in range(rows)]
    for y in range(rows): acc[y][0]=cost[y][0]
    for x in range(1,W):
        for y in range(rows):
            best=min((acc[yy][x-1],yy) for yy in (y-1,y,y+1) if 0<=yy<rows)
            acc[y][x]=cost[y][x]+best[0]; back[y][x]=best[1]
    y=min(range(rows),key=lambda r:acc[r][W-1]); cut=[0]*W
    for x in range(W-1,-1,-1):
        cut[x]=y; y=back[y][x]
    return cut
def vcut(left, right, cols):
    tl=[list(r) for r in zip(*left)]; tr=[list(r) for r in zip(*right)]
    return hcut(tl,tr,cols)
def grid(img): 
    p=img.load(); return [[p[x,y] for x in range(img.width)] for y in range(img.height)]
def build(sheet):
    im=Image.open(sheet).convert('RGBA')
    src=im.crop((0,4*T,T,6*T)); top=src.crop((0,0,T,T)); foot=src.crop((0,T,T,2*T))
    # B: one band of open-sided grass, 64 x 44 -- the foot's own left side
    # and grass, and the top's grass on the right where the foot has rock
    H=44
    L=grid(foot.crop((0,0,T,H))); Rg=grid(top.crop((0,20,T,20+H)))
    c=vcut([r[30:46] for r in L],[r[30:46] for r in Rg],16)
    B=[[ (L[y][x] if x<30+c[y] else Rg[y][x]) for x in range(T)] for y in range(H)]
    # stack: top, B, B, foot -- each join cut where the two agree best
    out=[[(0,0,0,0)]*T for _ in range(3*T)]
    def put(block,y0,ov):
        if ov:
            cur=[out[y0+y] for y in range(ov)]
            cut=hcut(cur,block[:ov],ov)
        for y in range(len(block)):
            for x in range(T):
                if ov and y<ov and y<cut[x]: continue
                out[y0+y][x]=block[y][x]
    put(grid(top),0,0)
    put(B,T-8,8)                 # rows 56..100
    put(B,T-8+H-8,8)             # rows 92..136 -- runs into the foot's place
    # ...and the foot, under the band's last eight rows, cut the same way
    fg = grid(foot)
    cut = hcut([B[H - 8 + y] for y in range(8)], fg[:8], 8)
    for y in range(T):
        for x in range(T):
            out[2 * T + y][x] = B[H - 8 + y][x] if y < 8 and y < cut[x] else fg[y][x]
    img=Image.new('RGBA',(T,3*T)); p=img.load()
    for y in range(3*T):
        for x in range(T): p[x,y]=out[y][x]
    return img

if __name__ == "__main__":
    for n in COLORS:
        build(SHEETS % n).save(OUT % n)
        print("wrote", OUT % n)
