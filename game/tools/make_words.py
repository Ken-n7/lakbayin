#!/usr/bin/env python3
"""The monks' words: Filipino words and their Baybayin spellings.

    python3 tools/make_words.py          # from the `game` directory

Writes `data/words.json` (the game: Practice and the results screen) and
`../supabase/words.sql` (the server, which checks answers). Run again after
changing WORDS; it checks itself first and writes nothing if a check fails.

Source: the Tagalog Swadesh list on Wiktionary
(https://en.wiktionary.org/wiki/Appendix:Tagalog_Swadesh_list), the standard
core-vocabulary list of linguistics, with its English glosses. Kept: native
content words of 2 to 4 syllables. Dropped: anything with r (the modern ra
glyph is unevenly supported, and old Baybayin shares one glyph for da/ra),
loan letters (c f j q v x z), hyphenated forms, pronouns and particles, and
loanwords (niyebe, yelo).

Spellings are made by rule, never typed by hand (DESIGN.md 4.2):
  - modern: a consonant with no vowel after it takes the krus-kudlit (U+1714)
  - traditional: that consonant is not written at all
Both are accepted as correct.
"""
import json
import os
import sys

# (word, English) from the Swadesh list, in its order. Words that appear twice
# there (asawa: wife/husband, balat: bark/skin, buto: seed/bone, puno:
# tree/full) are kept once with both meanings.
WORDS = [
    ("isa", "one"), ("dalawa", "two"), ("tatlo", "three"), ("apat", "four"),
    ("lima", "five"), ("malaki", "big"), ("mahaba", "long"), ("malapad", "wide"),
    ("makapal", "thick"), ("mabigat", "heavy"), ("maliit", "small"),
    ("maikli", "short"), ("makitid", "narrow"), ("manipis", "thin"),
    ("payat", "thin (of a body)"), ("babae", "woman"), ("lalaki", "man"),
    ("tao", "person"), ("anak", "child (offspring)"), ("bata", "child"),
    ("asawa", "wife, husband"), ("ina", "mother"), ("ama", "father"),
    ("hayop", "animal"), ("isda", "fish"), ("ibon", "bird"), ("aso", "dog"),
    ("kuto", "louse"), ("ahas", "snake"), ("uod", "worm"),
    ("puno", "tree; full"), ("gubat", "forest"), ("patpat", "stick"),
    ("bunga", "fruit"), ("buto", "seed; bone"), ("binhi", "seed (for planting)"),
    ("dahon", "leaf"), ("ugat", "root"), ("balat", "bark; skin"),
    ("bulaklak", "flower"), ("damo", "grass"), ("lubid", "rope"),
    ("laman", "meat"), ("dugo", "blood"), ("taba", "fat"), ("itlog", "egg"),
    ("sungay", "horn"), ("buntot", "tail"), ("balahibo", "feather"),
    ("buhok", "hair"), ("ulo", "head"), ("tainga", "ear"), ("mata", "eye"),
    ("ilong", "nose"), ("bibig", "mouth"), ("ngipin", "tooth"),
    ("dila", "tongue"), ("kuko", "fingernail"), ("paa", "foot"),
    ("binti", "leg"), ("tuhod", "knee"), ("kamay", "hand"), ("pakpak", "wing"),
    ("tiyan", "belly"), ("bituka", "guts"), ("leeg", "neck"), ("likod", "back"),
    ("puso", "heart"), ("atay", "liver"), ("uminom", "to drink"),
    ("kumain", "to eat"), ("kumagat", "to bite"), ("sumipsip", "to suck"),
    ("sumuka", "to vomit"), ("umihip", "to blow"), ("huminga", "to breathe"),
    ("tumawa", "to laugh"), ("makita", "to see"), ("alamin", "to know"),
    ("umamoy", "to smell"), ("matakot", "to fear"), ("matulog", "to sleep"),
    ("mabuhay", "to live"), ("mamatay", "to die"), ("pumatay", "to kill"),
    ("lumaban", "to fight"), ("mangaso", "to hunt"), ("tumama", "to hit"),
    ("pumutol", "to cut"), ("hatiin", "to split"), ("sumaksak", "to stab"),
    ("kamutin", "to scratch"), ("hukayin", "to dig"), ("lumangoy", "to swim"),
    ("lumipad", "to fly"), ("maglakad", "to walk"), ("dumating", "to come"),
    ("humiga", "to lie down"), ("umupo", "to sit"), ("tumayo", "to stand"),
    ("lumiko", "to turn"), ("mahulog", "to fall"), ("magbigay", "to give"),
    ("humawak", "to hold"), ("pumisil", "to squeeze"), ("magkuskos", "to rub"),
    ("maghugas", "to wash"), ("magpunas", "to wipe"), ("hilahin", "to pull"),
    ("tumulak", "to push"), ("magtapon", "to throw"), ("magtali", "to tie"),
    ("magtahi", "to sew"), ("magbilang", "to count"), ("magsabi", "to say"),
    ("umawit", "to sing"), ("lumutang", "to float"), ("umagos", "to flow"),
    ("tumigas", "to freeze"), ("mamaga", "to swell"), ("buwan", "moon"),
    ("bituin", "star"), ("tubig", "water"), ("ulan", "rain"), ("ilog", "river"),
    ("lawa", "lake"), ("dagat", "sea"), ("asin", "salt"), ("bato", "stone"),
    ("buhangin", "sand"), ("alikabok", "dust"), ("lupa", "earth"),
    ("ulap", "cloud"), ("hamog", "fog"), ("langit", "sky"), ("hangin", "wind"),
    ("usok", "smoke"), ("apoy", "fire"), ("abo", "ash"), ("magsunog", "to burn"),
    ("daan", "road"), ("bundok", "mountain"), ("pula", "red"),
    ("luntian", "green"), ("dilaw", "yellow"), ("puti", "white"),
    ("itim", "black"), ("gabi", "night"), ("taon", "year"),
    ("mainit", "hot"), ("malamig", "cold"), ("bago", "new"), ("luma", "old"),
    ("matanda", "old (of people)"), ("mabuti", "good"), ("masama", "bad"),
    ("bulok", "rotten"), ("madumi", "dirty"), ("tuwid", "straight"),
    ("bilog", "round"), ("matalim", "sharp"), ("makinis", "smooth"),
    ("basa", "wet"), ("tuyo", "dry"), ("tama", "correct"),
    ("malapit", "near"), ("malayo", "far"), ("kanan", "right"),
    ("kaliwa", "left"), ("ngalan", "name"),
]

VOWEL = {"a": "ᜀ", "e": "ᜁ", "i": "ᜁ", "o": "ᜂ", "u": "ᜂ"}
CONSONANT = {
    "k": "ᜃ", "g": "ᜄ", "ng": "ᜅ", "t": "ᜆ", "d": "ᜇ",
    "n": "ᜈ", "p": "ᜉ", "b": "ᜊ", "m": "ᜋ", "y": "ᜌ",
    "l": "ᜎ", "w": "ᜏ", "s": "ᜐ", "h": "ᜑ",
}
KUDLIT = {"a": "", "e": "ᜒ", "i": "ᜒ", "o": "ᜓ", "u": "ᜓ"}
VIRAMA = "᜔"
LETTERS = set("abdeghiklmnopstuwy")


def units(word):
    """The word as letters, "ng" as one consonant."""
    out, i = [], 0
    while i < len(word):
        if word[i:i + 2] == "ng":
            out.append("ng")
            i += 2
        else:
            out.append(word[i])
            i += 1
    return out


def spell(word, modern=True):
    """Baybayin for a Filipino word. modern: a vowelless consonant takes the
    krus-kudlit; traditional (modern=False): it is left out."""
    u = units(word)
    out = []
    for i, ch in enumerate(u):
        if ch in VOWEL:
            # A vowel after a consonant was already written as its kudlit.
            if i == 0 or u[i - 1] in VOWEL:
                out.append(VOWEL[ch])
            continue
        nxt = u[i + 1] if i + 1 < len(u) else None
        if nxt in VOWEL:
            out.append(CONSONANT[ch] + KUDLIT[nxt])
        elif modern:
            out.append(CONSONANT[ch] + VIRAMA)
    return "".join(out)


def syllables(word):
    return sum(1 for ch in units(word) if ch in VOWEL)


def check():
    # The worked examples in DESIGN.md 4.3, glyph by glyph.
    want = {
        "bata": "ᜊᜆ",
        "aso": "ᜀᜐᜓ",
        "bahay": "ᜊᜑᜌ᜔",
        "ibon": "ᜁᜊᜓᜈ᜔",
        "kain": "ᜃᜁᜈ᜔",
        "bundok": "ᜊᜓᜈ᜔ᜇᜓᜃ᜔",
        "ngipin": "ᜅᜒᜉᜒᜈ᜔",
        "tainga": "ᜆᜁᜅ",
    }
    for word, glyphs in want.items():
        assert spell(word) == glyphs, (word, spell(word))
    assert spell("bundok", modern=False) == "ᜊᜓᜇᜓ"
    assert spell("bahay", modern=False) == "ᜊᜑ"
    assert spell("bata", modern=False) == spell("bata")   # no final consonant: same
    assert syllables("bulaklak") == 3 and syllables("ngalan") == 2
    seen = set()
    for word, meaning in WORDS:
        assert set(word) <= LETTERS, word          # no r, no loan letters
        assert 2 <= syllables(word) <= 4, word
        assert word not in seen, word
        assert meaning, word
        seen.add(word)


def main():
    check()
    here = os.path.dirname(os.path.abspath(__file__))
    rows = [{"word": w, "meaning": m, "syllables": syllables(w),
             "modern": spell(w), "traditional": spell(w, modern=False)} for w, m in WORDS]
    with open(os.path.join(here, "..", "data", "words.json"), "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=1)
        f.write("\n")
    q = lambda s: "'" + s.replace("'", "''") + "'"
    values = ",\n".join("  (%s, %s, %d, %s, %s)" % (q(r["word"]), q(r["meaning"]), r["syllables"],
                        q(r["modern"]), q(r["traditional"])) for r in rows)
    sql = ("-- Generated by game/tools/make_words.py -- do not edit by hand.\n"
           "-- Run after schema.sql. Safe to re-run: it replaces the list.\n"
           "delete from public.words;\n"
           "insert into public.words (word, meaning, syllables, modern, traditional) values\n"
           + values + ";\n")
    with open(os.path.join(here, "..", "..", "supabase", "words.sql"), "w", encoding="utf-8") as f:
        f.write(sql)
    print("%d words written" % len(rows))


if __name__ == "__main__":
    sys.exit(main())
