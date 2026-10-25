"""Cuts the trailer and the gameplay video from showcase recordings (see
tools/showcase.py) with ffmpeg: shots, punch-ins, speed-ups, the game's own
words over them (tools/cards.gd), transitions, and the game's soundtrack under
its sound effects. Game assets only -- no generated images, voices or music.

  python3 game/tools/edit.py trailer|gameplay FOOTAGE_DIR OUT.mp4

FOOTAGE_DIR holds hero/ and room/ (each <name>.mp4, .wav, -sfx.wav,
.marks.json) and cards/ (PNGs from tools/cards.gd)."""
import hashlib, json, subprocess, sys
from pathlib import Path

GAME = Path(__file__).resolve().parents[1]
MUSIC = GAME / 'assets/music'
FPS = 30
W, H = 1920, 1080


def run(args):
    r = subprocess.run(['ffmpeg', '-v', 'error', '-y', *map(str, args)], stderr=subprocess.PIPE, text=True)
    if r.stderr:
        print(r.stderr[-3000:], file=sys.stderr)
    if r.returncode:
        print('exit', r.returncode, file=sys.stderr)
        sys.exit(f'ffmpeg failed: {args[-1]}')


def duration(path):
    return float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                                 '-of', 'csv=p=0', str(path)], capture_output=True, text=True).stdout)


class Footage:
    """One recording and its marks: `at('monk', 2)` is the third monk opened."""
    def __init__(self, base):
        self.base = Path(base)
        self.marks = json.loads(Path(f'{base}.marks.json').read_text())

    def at(self, name, n=0):
        hits = [t for m, t in self.marks if m == name]
        return hits[n] if n >= 0 else hits[n]

    def all(self, name):
        return [t for m, t in self.marks if m == name]


def shot(out, src, a, b, speed=1.0, zoom=None, cards=(), sfx=1.0, blur=False, letterbox=False,
         vignette=False, cards_dir=None):
    """One shot, rendered alone: `src` from `a` to `b` seconds, `speed` times
    as fast, `zoom` (z0, z1, cx, cy) a push from z0 to z1 aimed at (cx, cy) as
    fractions of the frame, `cards` [(png, from, to)] in the shot's own time."""
    d = (b - a) / speed
    args = ['-ss', a, '-t', b - a, '-i', f'{src}.mp4']
    vf = [f'setpts=(PTS-STARTPTS)/{speed}', f'fps={FPS}']
    if zoom:
        z0, z1, cx, cy = zoom
        if z0 == z1:
            vf += [f'crop={W / z0:.0f}:{H / z0:.0f}:{(W - W / z0) * cx:.0f}:{(H - H / z0) * cy:.0f}',
                   f'scale={W}:{H}:flags=lanczos']
        else:
            # Upscaled first: zoompan steps in whole pixels, which shakes.
            n = max(1, round(d * FPS))
            vf += [f'scale={W * 2}:{H * 2}:flags=neighbor',
                   f"zoompan=z='{z0}+({z1}-{z0})*on/{n}':x='(iw-iw/zoom)*{cx}':y='(ih-ih/zoom)*{cy}'"
                   f':d=1:s={W}x{H}:fps={FPS}']
    if blur:
        vf += ['gblur=sigma=18', 'eq=brightness=-0.12:saturation=0.8']
    if vignette:
        vf += ['vignette=angle=PI/5']
    if letterbox:
        vf += [f'drawbox=x=0:y=0:w={W}:h=132:color=black:t=fill',
               f'drawbox=x=0:y={H - 132}:w={W}:h=132:color=black:t=fill']
    graph = [f"[0:v]{','.join(vf)}[v0]"]
    last = 'v0'
    for k, (png, t0, t1) in enumerate(cards):
        args += ['-loop', 1, '-t', d, '-i', Path(cards_dir) / f'{png}.png']
        f = min(0.35, (t1 - t0) / 3)
        graph.append(f'[{k + 1}:v]format=rgba,fade=in:st={t0}:d={f}:alpha=1,'
                     f'fade=out:st={t1 - f}:d={f}:alpha=1[c{k}]')
        graph.append(f"[{last}][c{k}]overlay=0:'if(lt(t,{t0 + f}),(1-(t-{t0})/{f})*24,0)'"
                     f":enable='between(t,{t0},{t1})'[v{k + 1}]")
        last = f'v{k + 1}'
    # The sound effects at their own speed; sped-up shots go quiet.
    if speed <= 1.0 and sfx > 0:
        args += ['-ss', a, '-t', b - a, '-i', f'{src}-sfx.wav']
        graph.append(f'[{len(cards) + 1}:a]aresample=48000,aformat=channel_layouts=stereo,'
                     f'volume={sfx},apad,atrim=0:{d}[a]')
    else:
        graph.append(f'anullsrc=r=48000:cl=stereo,atrim=0:{d}[a]')
    run([*args, '-filter_complex', ';'.join(graph), '-map', f'[{last}]', '-map', '[a]',
         '-t', d, '-c:v', 'libx264', '-preset', 'medium', '-crf', 17, '-pix_fmt', 'yuv420p',
         '-c:a', 'pcm_s16le', out])
    return duration(out)


def join(out, parts):
    """[(path, length, transition, t)] -> one file: each part into the next by
    `transition` (an xfade name) over t seconds, or 'cut'. Runs of cuts are
    stitched first without re-encoding: thirty 1080p inputs open at once in
    one filter graph ran this laptop out of memory."""
    chunks, run_ = [], []
    for p in parts:
        run_.append(p)
        if p[2] != 'cut' or p is parts[-1]:
            chunks.append(run_)
            run_ = []
    files = []
    for k, c in enumerate(chunks):
        lst = Path(out).with_name(f'chunk{k}.txt')
        lst.write_text(''.join(f"file '{p[0]}'\n" for p in c))
        f = Path(out).with_name(f'chunk{k}.mov')
        run(['-f', 'concat', '-safe', 0, '-i', lst, '-c', 'copy', f])
        files.append((f, duration(f), c[-1][2], c[-1][3]))
    args, graph = [], []
    for p, *_ in files:
        args += ['-i', p]
    v, a, end = '0:v', '0:a', files[0][1]
    for i in range(1, len(files)):
        kind, t = files[i - 1][2], files[i - 1][3]
        end -= t
        graph.append(f'[{v}][{i}:v]xfade=transition={kind}:duration={t:.4f}:offset={end:.4f}[v{i}]')
        graph.append(f'[{a}][{i}:a]acrossfade=d={t:.4f}:c1=tri:c2=tri[a{i}]')
        v, a = f'v{i}', f'a{i}'
        end += files[i][1]
    run([*args, '-filter_complex', ';'.join(graph) or '[0:v]null[v0];[0:a]anull[a0]',
         '-map', f'[{v}]', '-map', f'[{a}]', '-c:v', 'libx264', '-preset', 'medium', '-crf', 17,
         '-pix_fmt', 'yuv420p', '-c:a', 'pcm_s16le', out])
    return end


def finish(out, joined, length, music, sfx_gain=1.0, fade_in=0.6, fade_out=1.5):
    """Music under the joined cut: [(track, at, length, from, fade in, fade out,
    volume)], looped when the track is shorter; then loudness for the web."""
    args, graph, mix = ['-i', joined], [], [f'[0:a]volume={sfx_gain}[s]']
    for k, (track, at, d, start, fi, fo, vol) in enumerate(music):
        args += ['-stream_loop', -1, '-ss', start, '-i', MUSIC / f'{track}.ogg']
        graph.append(f'[{k + 1}:a]aresample=48000,aformat=channel_layouts=stereo,atrim=0:{d},'
                     f'afade=in:d={fi},afade=out:st={d - fo}:d={fo},volume={vol},'
                     f'adelay={int(at * 1000)}:all=1[m{k}]')
    ins = '[s]' + ''.join(f'[m{k}]' for k in range(len(music)))
    graph += mix
    graph.append(f'{ins}amix=inputs={len(music) + 1}:normalize=0:duration=first,'
                 f'loudnorm=I=-14:TP=-1.5:LRA=11,aresample=48000[a]')
    graph.append(f'[0:v]fade=in:d={fade_in},fade=out:st={length - fade_out}:d={fade_out}[v]')
    run([*args, '-filter_complex', ';'.join(graph), '-map', '[v]', '-map', '[a]', '-t', length,
         '-c:v', 'libx264', '-preset', 'slow', '-crf', 18, '-pix_fmt', 'yuv420p',
         '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart', out])


def build(plan, footage, out, sfx_gain=1.0, end_music=1.5):
    """`plan`: shots (the keywords of `shot`, plus `src`, `trans` into the
    next, and `music` (track, from, volume) to start under that shot -- the
    track before it handing over in a crossfade)."""
    # Shots are kept beside the output, named by what they are: a change to
    # one plan entry renders that shot again, not all of them.
    tmp = Path(f'{out}.shots')
    tmp.mkdir(exist_ok=True)
    parts, starts, cues, at = [], [], [], 0.0
    for i, s in enumerate(plan):
        s = dict(s)
        src = footage[s.pop('src')]
        trans = s.pop('trans', ('cut', 0))
        if 'music' in s:
            cues.append((at, *s.pop('music')))
        seen = [(Path(footage['cards']) / f'{c[0]}.png').stat().st_mtime for c in s.get('cards', ())]
        key = hashlib.sha1(json.dumps([str(src.base), s, seen], sort_keys=True, default=str).encode()).hexdigest()[:12]
        p = tmp / f'{key}.mov'
        if not p.exists():
            shot(tmp / 'part.mov', src.base, cards_dir=footage['cards'], **s)
            (tmp / 'part.mov').rename(p)
        length = duration(p)
        parts.append((p, length, *trans))
        starts.append(at)
        at += length - (0 if trans[0] == 'cut' else trans[1])
        print(f'shot {i:2} at {starts[-1]:6.1f}: {length:5.1f}s', flush=True)
    length = join(Path(tmp) / 'joined.mov', parts)
    music, x = [], 1.5
    for k, (t, track, start, vol) in enumerate(cues):
        end = cues[k + 1][0] + x if k + 1 < len(cues) else length
        music.append((track, t, end - t, start, x if k else 0.3, x if k + 1 < len(cues) else end_music, vol))
    finish(out, Path(tmp) / 'joined.mov', length, music, sfx_gain)
    print(f'{out}: {length:.1f}s')


# --- The gameplay video ---------------------------------------------------------------
def gameplay(H, R):
    m = H.at
    P = []
    add = P.append
    fade = ('fade', 0.5)
    # Open: the name over the menu.
    add(dict(src='hero', a=0.2, b=6.2, blur=True, cards=[('logo', 0.4, 5.7), ('real', 1.2, 5.7)], trans=('fade', 0.8),
             music=('where_the_winds_roam', 0.6, 0.5)))
    # Learn Baybayin: How to Play, page by page.
    add(dict(src='hero', a=0.5, b=3.0, blur=True, cards=[('s_learn', 0.2, 2.5)], trans=fade))
    add(dict(src='hero', a=1.0, b=m('guide_2'), cards=[('c_guide', 0.6, 5.2)]))
    for a, b in [('guide_2', 'guide_3'), ('guide_3', 'guide_4'), ('guide_4', 'guide_5'), ('guide_5', 'guide_6')]:
        add(dict(src='hero', a=m(a) - 0.2, b=m(b)))
    add(dict(src='hero', a=m('guide_6') - 0.2, b=m('guide_end') + 0.8, trans=fade))
    # Play a match.
    add(dict(src='hero', a=m('queue') + 4.0, b=m('queue') + 6.5, blur=True, cards=[('s_play', 0.2, 2.5)],
             trans=fade, music=('port_town', 2.1, 0.45)))
    add(dict(src='hero', a=m('find') - 0.3, b=m('queue') + 0.6, cards=[('c_find', 0.4, 5.6)]))
    add(dict(src='hero', a=m('queue') + 0.6, b=m('match') - 2.4, speed=2.0, cards=[('ff2', 0, 99)]))
    add(dict(src='hero', a=m('match') - 2.4, b=m('play'), cards=[('c_intro', 3.0, 7.6)],
             music=('the_journey', 0.0, 0.45)))
    add(dict(src='hero', a=m('play'), b=m('submit', 0) + 2.4,
             cards=[('c_walk', 0.2, 3.6), ('c_type', m('type', 0) - m('play') + 0.3, m('submit', 0) - m('play')),
                    ('c_correct', m('submit', 0) - m('play') + 0.5, m('submit', 0) - m('play') + 2.4)]))
    w = m('wrong')
    add(dict(src='hero', a=m('submit', 0) + 2.4, b=w + 3.2,
             cards=[('c_wrong', w - m('submit', 0) - 2.2, w - m('submit', 0) + 0.8)]))
    add(dict(src='hero', a=w + 3.2, b=m('type', 1) - 0.6, speed=4.0, cards=[('ff4', 0, 99)]))
    add(dict(src='hero', a=m('type', 1) - 0.6, b=m('walk_door', 0)))
    add(dict(src='hero', a=m('walk_door', 0), b=m('deposit', 0) - 0.4, speed=2.0, cards=[('ff2', 0, 99)]))
    add(dict(src='hero', a=m('deposit', 0) - 0.4, b=m('walk_monk', 2), cards=[('c_deposit', 0.4, 3.2)]))
    add(dict(src='hero', a=m('walk_monk', 2), b=m('monk', 2), speed=2.0,
             cards=[('ff2', 0, 99), ('c_race', 0.1, 3.2)]))
    add(dict(src='hero', a=m('monk', 2), b=m('walk_door', 1)))
    add(dict(src='hero', a=m('walk_door', 1), b=m('deposit', 1) - 0.4, speed=2.0, cards=[('ff2', 0, 99)]))
    if m('results') - m('deposit', 1) > 9:
        # Waiting on teammates to finish it: the wait fast, the end as it is.
        add(dict(src='hero', a=m('deposit', 1) - 0.4, b=m('deposit', 1) + 3.5))
        add(dict(src='hero', a=m('deposit', 1) + 3.5, b=m('results') - 3.5, speed=2.0, cards=[('ff2', 0, 99)]))
        add(dict(src='hero', a=m('results') - 3.5, b=m('results') + 0.3, trans=fade))
    else:
        add(dict(src='hero', a=m('deposit', 1) - 0.4, b=m('results') + 0.3, trans=fade))
    # After the match.
    add(dict(src='hero', a=m('results') + 0.5, b=m('results') + 3.0, blur=True, cards=[('s_after', 0.2, 2.5)],
             trans=fade, music=('victory', 8.5, 0.45)))
    add(dict(src='hero', a=m('results') + 0.3, b=m('records'), cards=[('c_results', 0.6, 4.6)]))
    add(dict(src='hero', a=m('records'), b=m('home_end') + 0.2, cards=[('c_records', 0.5, 4.2)], trans=fade))
    if R is not None:
        r = R.at
        add(dict(src='room', a=r('create') - 0.8, b=r('create') + 1.7, blur=True,
                 cards=[('s_friends', 0.2, 2.5)], trans=fade, music=('definitely_our_town', 23.1, 0.45)))
        add(dict(src='room', a=r('home') + 0.5, b=r('spectate') + 2.0, cards=[('c_room', 0.6, 5.0)]))
        add(dict(src='room', a=r('spectate') + 2.0, b=r('full'), speed=2.0, cards=[('ff2', 0, 99)]))
        add(dict(src='room', a=r('full'), b=r('watch') + 0.5))
        f = R.all('follow')
        add(dict(src='room', a=r('watch') + 0.5, b=f[0], cards=[('c_watch', 0.6, 5.0)],
                 music=('battle_2', 0.6, 0.4)))
        add(dict(src='room', a=f[0], b=min(f[0] + 26, R.at('watch_end'))))
        st = R.all('stats')
        if st:
            add(dict(src='room', a=st[0] - 0.5, b=st[0] + 4.5))
    # Practice, then the name again.
    add(dict(src='hero', a=m('home_end') + 0.2, b=m('home_end') + 2.8, cards=[('c_practice', 0.2, 2.6)],
             trans=('fade', 0.8)))
    add(dict(src='hero', a=0.2, b=6.0, blur=True,
             cards=[('logo_end', 0.5, 5.8), ('credits', 0.5, 5.8)], music=('victory', 0.0, 0.45)))
    return P


# --- The trailer -------------------------------------------------------------------------
BEAT = 0.650          # battle_1: 92.3 beats a minute
FIRST = 0.511         # its first beat


def trailer(H, R):
    m, r = H.at, R.at
    P = []

    def B(src, a, n, trans=('cut', 0), speed=1.0, lead=0.0, **kw):
        """A shot `n` beats long, its cut on the beat: what the transition
        into the next eats is added back."""
        t = 1 / FPS if trans[0] == 'cut' else trans[1]
        P.append(dict(src=src, a=a, b=a + (n * BEAT + lead + t) * speed, speed=speed, trans=trans, **kw))

    film = dict(letterbox=True, vignette=True)
    f = R.all('follow')
    flash = ('fadewhite', 0.25)
    # Act one: the island, the monks, the script.
    B('room', r('watch') + 1.0, 8, lead=FIRST, zoom=(1.0, 1.12, 0.5, 0.5), cards=[('t_island', 1.0, 5.2)],
      music=('battle_1', 0.0, 0.9), **film)
    B('hero', m('monk', 0) + 0.6, 4, zoom=(1.35, 1.35, 0.12, 0.3), cards=[('t_word', 0.2, 2.5)], **film)
    B('hero', m('type', 0), 8, zoom=(1.0, 1.12, 0.6, 0.5), cards=[('t_write', 0.3, 4.9)], sfx=0.6, **film)
    B('hero', m('deposit', 0) - 3.0, 8, cards=[('t_carry', 0.3, 4.9)], sfx=0.6, **film)
    B('room', f[1], 8, zoom=(1.0, 1.08, 0.5, 0.5), cards=[('t_race', 0.3, 4.9)], trans=flash, **film)
    # Montage.
    B('hero', m('queue') + 4.0, 2, speed=3.0)
    B('hero', m('match') - 2.4, 2)
    B('hero', m('swoop') + 0.2, 4, sfx=0.6)
    B('hero', m('walk_monk', 1) + 0.5, 2)
    B('hero', m('type', 2) + 0.5, 2, zoom=(1.5, 1.5, 0.75, 0.5), sfx=0.6)
    B('hero', m('submit', 2) + 0.2, 2, sfx=0.6)
    B('hero', m('wrong') + 0.3, 2, zoom=(1.4, 1.4, 0.2, 0.62), sfx=0.6)
    B('room', f[2], 2, zoom=(1.2, 1.2, 0.5, 0.5))
    B('hero', m('deposit', 1) - 0.2, 2, sfx=0.6)
    if R.all('stats'):
        B('room', R.all('stats')[0] + 0.5, 2)
    B('hero', m('results') - 3.0, 2)
    B('hero', m('results') + 0.3, 2, zoom=(1.3, 1.3, 0.5, 0.15), sfx=0.6, trans=flash)
    # The game in a line, and what it teaches.
    B('room', f[3], 8, zoom=(1.15, 1.0, 0.5, 0.5), cards=[('t_team', 0.3, 4.9)], **film)
    B('hero', m('guide_3') + 0.5, 8, zoom=(1.15, 1.15, 0.3, 0.4), cards=[('t_learn', 0.3, 4.9)], **film)
    B('hero', m('guide_5') + 6.0, 2)
    B('room', r('full') - 1.0, 2)
    B('hero', m('find') + 1.5, 2)
    B('hero', m('words') + 1.5, 2)
    B('hero', m('board') + 0.5, 2)
    B('room', f[4], 2, zoom=(1.3, 1.3, 0.5, 0.5), trans=flash)
    # The name.
    B('room', r('watch') + 2.0, 12, blur=True, zoom=(1.0, 1.1, 0.5, 0.5), cards=[('logo', 0.4, 7.6)],
      trans=('fade', 0.5))
    B('hero', 0.2, 8, lead=0.3, blur=True, cards=[('logo_end', 0.3, 5.5), ('credits', 0.3, 5.5)])
    return P


if __name__ == '__main__':
    kind, root, out = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
    room = root / 'room/watch'
    footage = {'hero': Footage(root / 'hero/hero'), 'cards': root / 'cards',
               'room': Footage(room) if Path(f'{room}.marks.json').exists() else None}
    if kind == 'gameplay':
        build(gameplay(footage['hero'], footage['room']), footage, out)
    else:
        build(trailer(footage['hero'], footage['room']), footage, out, end_music=3.0)
