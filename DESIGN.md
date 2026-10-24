# Lakbayin — Game Design

> **Source of truth** for the DOST Level Up 3.0 Esports Game Dev Challenge entry.
> Edit this file when a decision changes. Open questions are at the bottom.

| | |
|---|---|
| Competition | DOST Level Up 3.0 Esports Game Dev Challenge — Student Category |
| Themes | **Education** (primary), Philippine culture (originality criterion) |
| Format | PvP, team vs team, time-limited matches |
| Platforms | Android (landscape), Windows |
| Entry deadline | **2026-10-25** (trailer + gameplay video + forms) |
| Finalists announced | 2026-11-09 |
| Finals | 2026-11-26/27, NSTW, General Santos City |

---

## 1. The pitch

Two teams of three race across a procedurally generated island world. Monks are
scattered across it, each holding a **Filipino word**. Find a monk, write its
word in **Baybayin** on the Baybayin keypad, carry the answer back, and deposit
it at the **Monastery**, which is hidden somewhere on the map. The first team to
deposit every word wins. If time runs out first, the team with more deposited
answers wins.

Players learn to **write Filipino in Baybayin**, the pre-colonial script, under
the pressure of a race against another team.

> Wording for the synopsis: this is **transliteration** (writing Filipino words
> in the Baybayin script), not translation. *Bahay* written in Baybayin is
> still *bahay*.

---

## 2. Core loop

```
explore the map ─► find a monk ─► type its word in Baybayin ─► carry the answer
      ▲                                                              │
      └──────────── deposit at the Monastery (when you choose) ◄─────┘
```

1. **Explore.** The world is new every match. Look around the map and split up
   with teammates to find monks and the Monastery.
2. **Answer.** Walk up to a monk. It shows a Filipino word. Type it in Baybayin
   on the keypad.
3. **Carry.** A correct answer is carried, not scored. A player can carry any
   number of answers. When to deposit is their own strategy.
4. **Deposit.** Interact with the Monastery to deposit everything you carry.
   Only deposited answers count.
5. **Finish.** A team finishes when every monk's word has been deposited and a
   player interacts with the Monastery.

---

## 3. Match rules

### 3.1 Teams and fairness
- **3 v 3** in matchmaking. Custom rooms allow any number a side, uneven too.
- Both teams play the **same world**: the same monk positions, the **same words**,
  and the same Monastery.
- Each team spawns at its own point. The Monastery is placed at an **equal
  walking distance from both spawns** (see §5), so "random" never favours one
  team.

### 3.2 Monks and answers
- Each monk holds one Filipino word (words only, no phrases).
- **Each monk is answered once per team.** Both teams can answer the same monk.
  Once a teammate has answered it, it greys out for the rest of that team.
- While a teammate is typing at a monk, it shows as **busy** to the rest of
  that team, so two players don't waste time on the same word. This is an
  advisory marker, not a lock. It clears on close or lockout and expires
  after 12 s without renewal; typed answers are never included in presence.
- **Wrong answer:** that player is locked out of that monk for **10 s**.
  Teammates can still try it. The correct spelling is **not** shown during the
  match, or the team would just copy it.
- An answer belongs to the player who typed it. Only that player can deposit it.

### 3.3 Carry and deposit
- Carried answers have no limit.
- **Answers still carried when time runs out are lost.** This is the risk:
  deposit often and walk more, or gather more first and risk losing them.
- The server holds carried answers, so a player who disconnects and comes back
  still has them.

### 3.4 Ending
- The match **ends for everyone** the moment a team **finishes** (every monk
  deposited), or when the **clock runs out**.
- When it ends, everyone sees an **aerial view** of the whole map, then the
  results screen.
- Match clock: **15 minutes**. Default monk count: **10**.
- **No leaving an online match.** The match's Settings (⚙, top right) holds
  only Music and Sounds; **Leave Practice** appears in Practice alone.

### 3.4a The match screen
- Top bar: the **minimap** top-left (its rim in your team's colour, which is
  how the screen says your side), the score ribbon, Carry, the clock, ⚙.
- The minimap is an **aerial picture of the island** -- land, trees, houses,
  rocks -- rendered once at the start. The **Monastery** and the **monks**
  are not in it: a monk appears as a dot once anyone on your team has seen
  it, and the Monastery as a small building once your team has found it.

### 3.5 Winning and ranking

**Ranking is by points first, then time.**

1. More deposited answers ranks higher, regardless of time.
2. Equal answers: whoever **reached that total first** ranks higher.

| Case | Result |
|---|---|
| Both finished | Same total, so the faster one ranks higher |
| Both have 9 | The one who deposited their 9th answer earlier ranks higher |
| Same time, different totals | The higher total ranks higher; time only breaks ties |

- **Team result:** a team that finishes beats any team that didn't. Otherwise
  the rule above applies to team totals.
- **Player ranking inside a match** (MVP list): the same rule, on each player's
  own deposits. This is "placed by contribution and time". Players tied on
  both share a rank in Results and My Matches.
- **One number on screen**, if needed:
  `score = deposited × 10000 + seconds_left_when_reached`. It sorts exactly
  like the two-step rule, because time can never outweigh one answer.
- **1 point per deposited word**, whatever its length.

### 3.6 Learning moment
The results screen lists **every word of the match with its Baybayin
spelling**, marking which ones your team got right, got wrong, or missed.
English meanings are not shown.

---

## 4. Baybayin keypad and answer checking

### 4.1 Layout — 20 keys + backspace, 3 rows of 7

```
 ᜀ a   ᜁ e/i  ᜂ o/u │ ᜃ ka   ᜄ ga   ᜅ nga  ᜆ ta
 ᜇ da  ᜈ na   ᜉ pa    ᜊ ba   ᜋ ma   ᜌ ya   ᜎ la
 ᜏ wa  ᜐ sa   ᜑ ha  │ ◌ᜒ i   ◌ᜓ u   ◌᜔ ×    ⌫
```

- 3 vowels, 14 consonants, and 3 marks:
  - **kudlit above** ◌ᜒ (U+1712): *ba* → *bi/be*
  - **kudlit below** ◌ᜓ (U+1713): *ba* → *bu/bo*
  - **vowel-cancelling mark** ◌᜔ (U+1714, krus-kudlit / virama): *ba* → *b*
- Marks combine with the glyph before them. The font shapes ᜊ + ◌ᜒ into ᜊᜒ.
- Each key shows a small **Latin label** under the glyph (ᜊ *ba*) **in
  Practice only**. Matchmade and custom games show the glyphs alone.
- The modern ᜍ *ra* (U+170D) is **left out**. Font support is uneven, and ᜇ
  covered da/ra traditionally.
- Font: **Noto Sans Tagalog** (SIL OFL). Credit it on the Credits screen.

### 4.2 Answer checking (server)
- The phone sends the typed Unicode string. **The server decides** whether it
  is correct.
- **Both conventions are correct:**
  - **Modern / reformed:** final consonants written with the vowel-cancelling
    mark: *bundok* → ᜊᜓᜈ᜔ᜇᜓᜃ᜔.
  - **Traditional** (before 1620): consonants without a vowel are not
    written: *bundok* → ᜊᜓᜇᜓ.
  - The results screen shows the modern form.
- Tolerances before comparing:
  - U+1714 and U+1715 (both styles of the vowel-cancelling mark) count as
    the same.
  - ᜇ is accepted for both *da* and *ra*. The word list avoids *r* anyway.
- e/i and o/u share one kudlit each, so writing has no ambiguity there.
- Spellings are **generated by rule** from each word (syllabify, then map),
  not typed per word, so the list cannot hold typos. The rule is tested
  against the worked examples in §4.3.

### 4.3 Examples

| Filipino | Baybayin | Keys |
|---|---|---|
| bata | ᜊᜆ | ᜊ ᜆ |
| aso | ᜀᜐᜓ | ᜀ ᜐ ◌ᜓ |
| bahay | ᜊᜑᜌ᜔ | ᜊ ᜑ ᜌ ◌᜔ |
| ibon | ᜁᜊᜓᜈ᜔ | ᜁ ᜊ ◌ᜓ ᜈ ◌᜔ |
| kain | ᜃᜁᜈ᜔ | ᜃ ᜁ ᜈ ◌᜔ |
| bundok | ᜊᜓᜈ᜔ᜇᜓᜃ᜔ (modern) · ᜊᜓᜇᜓ (traditional) | ᜊ ◌ᜓ ᜈ ◌᜔ ᜇ ◌ᜓ ᜃ ◌᜔ |

### 4.4 Word list
- About **150 common Filipino words**, from 2 to 4 syllables.
- **Sources:**
  - Words: [TagalogDecks top 2,000](https://tagalog.com/flashcards/top_two_thousand_words.php)
    (frequency from transcribed everyday speech), cross-checked against the
    UCLA corpus ranking (Zuraw 2006).
  - Spelling conventions: [Baybayin (Wikipedia)](https://en.wikipedia.org/wiki/Baybayin)
    for the krus-kudlit history, the Learn Baybayin guide
    ([baybayin.sourceforge.net](https://baybayin.sourceforge.net)) for the
    traditional style, and the Unicode Tagalog block for the characters. The
    official reference is the KWF's *Baybayin: ortograpiya at mga tuntunin sa
    pagsulat sa wikang Tagalog* (de Castro, 2014), which is not online; check
    against it if a copy can be found.
- **Filters:** native words only; no *r*; no *f, v, z, c, j, q, x*; no
  particles or words with unusual spellings (*ng*, *mga*).
- Each entry has the word, its generated Baybayin spelling (§4.2) and its
  English meaning as source metadata; results show Filipino and Baybayin only.
- Each match picks its words at random from the list, so no two matches are
  alike.

---

## 5. The world

### 5.1 Procedural generation
- Each match has one **seed**. Every phone builds the identical world from
  it, and so do the spectator view and reconnecting players.
- Every match is a different layout of islands, terrain, props, monks and the
  Monastery.
- Guarantees the generator must keep:
  - every monk and the Monastery are reachable from both spawns
  - **the Monastery is at an equal path distance from both spawns** (within a
    small tolerance). A mirrored layout is the easy way to get this.
  - monks are spread out, not clustered, with no monk inside a spawn area
- The existing seed system (both phones build the same board from the session
  id) is kept. The hand-made fixed board and tower pool go.

### 5.2 Art — Tiny Swords (Pixel Frog)
- **Used:** Monk (Idle), Pawn, Houses, **Monastery** (the "church"), terrain,
  trees, bushes, plain rocks, water rocks, clouds, water.
- The Monastery is **Purple**: it belongs to neither team. Monks stand
  **Black** until your team answers them, then turn your colour.
- **Removed:** towers, warriors and knights, archers, castles, barracks, the
  archery range, carved maths rocks.
- **Player characters:** all 32 Super Retro World heroes, for now. The pack
  is anime fantasy; if a more pre-colonial look is wanted later, the closest
  are #14 (villager), #11 and #19 (near-black hair), #7 and #23 (morena,
  warriors) and #1 (headband, like a *putong*), and the license allows
  recolouring them.
- **Team colours:** the pack has Monk and Monastery in Blue, Red, Yellow,
  Purple and Black. Blue and Red are the two teams.
- Above each monk: decorative Baybayin glyphs drift, replacing the old maths
  symbols. They are **not** the answer. The word itself appears on the answer
  panel.
- Menus and backdrop: the floating maths symbols become Baybayin glyphs.
- **Menu scenery:** Home is a Monastery village with two houses,
  black monks with decorative Baybayin, and the selected adventurer. The
  shared backdrop slowly pans across monastery, village and forest islands.
  Both use existing Tiny Swords / Super Retro World art; obsolete castles,
  towers, barracks, archery buildings and combat units are absent. These are
  fixed decorative scenes, separate from procedural match generation.

---

## 6. Game modes

### 6.1 Find Match (ranked)
- Press **Find Match** and the server puts you in the oldest open lobby, or
  opens one.
- Players are dealt onto the smaller team and cannot switch.
- A match starts **only when full** (3 v 3), so the teams are always even.
- A player still waiting after **90 s** (`match_config.search_s`) drops out of
  the queue: "No match found — tap Find Match to search again."
- Team size is one setting (`match_config.team_size`, 1 to 5). It is **3** by
  default; **1** also supports two-phone testing. The live project remains
  at **1** by request; custom rooms can still test 3 v 3.
- Lobby phones check in every few seconds. One silent for 15 s loses its place.
  The lobby shows "Searching for players — 4 of 6 · 1:07 left".
- **Counts for the global leaderboard.**

### 6.2 Custom Room (with friends)
- **Create Room:** the host gets a 4-character code.
- **Join Room:** type the code to land in the lobby.
- Players pick sides and may switch until Start. The host may **Move Player**
  or **Shuffle** everyone into balanced sides. Both controls lock at Start.
- **Spectators:** anyone in the room, the host included, may pick the
  **Spectators** bar instead of a side. A spectator never plays: no hero, no
  answers or deposits, no results or records. At Start they get the Watch
  view (§6.4). Nobody switches between playing and spectating after Start;
  Shuffle leaves spectators where they are.
- **Only the host starts**, once both sides have a player (spectators do not
  count). Any number a side, uneven too (1 v 3 is fine).
- If the host leaves the lobby, hosting passes to the next player. Lobby
  phones check in every 3 s; 30 s silence removes a disconnected member,
  transferring hosting to the oldest active member when necessary. Running
  match memberships and results are retained.
- Shows in **My Matches** with a **Custom** tag, but does **not** count for
  the global leaderboard (rigged rooms could farm it), as MOBAs do.

### 6.3 Practice (solo, offline)
- The same rules, alone, with no server.
- For learning the keypad, for judges trying the game, and for recording
  gameplay video without 6 players.

### 6.4 Watch (spectator)
- An aerial view of a live match, for the event screen at NSTW.
- Shows both teams, monk states, and carried and deposited counts.
- Open **Custom Room**, enter the live code, and press **Watch**. A viewer
  waits through the lobby and sees the same seeded island when play starts.
- Viewers never join a team or submit answers, deposits, or movement. Each
  monk has separate Blue/Red markers: an outline is carried, a fill deposited.
- The event screen keeps the final result visible until the viewer leaves.
- The view can be moved: drag to pan; scroll, pinch or **+ / −** to zoom,
  from the whole island to about five times closer.

---

## 7. Leaderboards and history

| Screen | Contents |
|---|---|
| **Match results** | Winner, team totals, player ranking (§3.5), every word with its Baybayin spelling (§3.6) |
| **Global leaderboard** | Players from matchmade games only: **wins**, then **total answers deposited** |
| **My Matches** | Your matches, newest first: result, rank, deposits. Custom games tagged **Custom** |

There is no team leaderboard: matchmade teams are random, so an all-time team
board means nothing.

Open **Player Records** on Home, or **My Matches** after an online match.
Records show 20 entries per page. Only games that actually started and ended
(or reached their deadline) count; abandoned lobbies do not. Exact ties are
recorded as draws and award no global wins. Practice stays offline.

---

## 8. Removed

| Area | Removed |
|---|---|
| Teacher mode | Admin role and the role choice at sign-up, teacher dashboard, Game Controls, Question Bank, Feedback, pause, removing players after Start, the teacher's position hub (PosHub), the teacher-hosted relay, teacher History |
| Old rules | Gems, hints, skip, Rescue, elimination, perfect-station bonus, combo, race bonus, the −25 unfinished penalty |
| Old structure | The 3 stations, circle order, station briefings and intro cards, knights and gates (barricades), Victory Gate (replaced by the Monastery) |
| Maths | Question generator, maths text formatting, maths symbols, Learn screen (already removed) |
| Matchmaking | The "house" admin account in `match_config`: words come from the server's word list, and whoever opens a lobby owns it |
| Files | Client PDFs, the old spec, merge checklist (already removed) |

## 9. Kept and reworked

| Kept | Becomes |
|---|---|
| Join by code + team picker + move/shuffle + Start | **Custom rooms**, run by a player host |
| Matchmaking (`find_match` / `poll_match` / `leave_match`) | Find Match, at 3 v 3 |
| Spectating after finishing + the teacher's map view | Aerial view at match end + **Watch** mode |
| Offline team-name start | **Practice** mode |
| Floating symbols (`TowerSymbols`) | Decorative Baybayin glyphs |
| History | **My Matches** |
| Leaderboard | Global player board |
| Session seed → identical board on every phone | Seed for the procedural world |
| Hero select, settings, credits, movement, multiplayer, tiebreak | Kept; username-only auth and WebSocket transport now self-hosted |

---

## 10. Technical design

### 10.1 Stack
- **Client:** Godot 4.6, GDScript. Android APK and Windows build.
- **Backend:** self-hosted FastAPI + SQLite on the user's server, published
  to the public Internet at `https://server.lakbayin.space` through a named
  Cloudflare Tunnel. Registration stays at Namecheap; Cloudflare handles DNS
  and transport. The named tunnel is live; public HTTPS auth and WSS gameplay
  have been verified with two Godot clients.
- **Accounts:** username and password only; no email, confirmation or password
  reset. Argon2id hashes protect passwords. Random 256-bit opaque sessions are
  stored hashed on the server, expire after 30 days and are revoked on logout.
  The app stores its session separately from the former provider's sessions.
- **Realtime:** authenticated WebSockets through the same server and tunnel;
  movement is sampled/sent every 50 ms, with heartbeat/reconnect and scoped
  room access. No shared hosted-provider message budget or separate relay is
  needed. Movement remains client simulated; the server binds each packet to
  its authenticated player. World collision and proximity are not independently
  simulated on the Python server.
- **Persistence:** SQLite transactions checkpoint rosters, words, lockouts,
  carried/deposited answers, timers, outcomes and records. A restart retains
  these and the original absolute deadline; it does not pause the match clock.
  Transient positions/presence reconnect; positions are not checkpointed.
- **Runtime:** one server worker owns live sockets. Loopback HTTP/WS is used
  for local tests; public clients use HTTPS/WSS. Enabled systemd user services
  restart the server and tunnel automatically; user lingering is enabled,
  allowing startup before login. No Supabase runtime access is needed.
  Former SQL remains archived for reference; existing remote accounts and
  history are not imported or deleted. Players create new local accounts.

### 10.2 The server is authoritative
The phone never decides an outcome. The server:
- picks the match's words and seed
- checks every answer (§4.2)
- records which monks each team has answered
- holds carried answers and records deposits, with their times
- decides finishing, the end of the match and the ranking

### 10.3 Data (sketch)

| Table | Holds |
|---|---|
| `sessions` | Match: kind (`ranked` / `custom`), host, code, state, seed, clock, `starts_at` |
| `teams`, `members` | Who is on which side; per player: carried count, deposited count, `reached_at` (time of their last deposit) |
| `match_words` | Per match: monk index → word, Baybayin spelling (never sent to phones before the match ends) |
| `answers` | Per team and monk: answered by whom, when, deposited or carried |
| `words` | The word list (§4.4) |
| `match_config` | Team size, lobby countdown, clock, monk count |

### 10.4 Server calls (sketch)
- `find_match()`, `poll_match(session)`, `leave_match(session)` — exist
- `create_room()`, `join_room(code)`, `start_room(session)` — custom rooms
- `answer(session, monk, typed)` → correct / wrong / locked
- `deposit(session)` → this player's carried answers become deposited; may
  finish the team
- The match ends on the first team to finish or on the clock, whichever comes
  first.

### 10.5 Security
- Answers are checked on the server, against spellings phones never receive
  until the match ends.
- A player can only answer, carry and deposit as themselves.
- Custom games are excluded from the global board.

---

## 11. Credits and AI disclosure
- **Art:** Tiny Swords by Pixel Frog. Characters: Super Retro World by Gif
  (@gif_not_jif), Noiracide (@Noiracide) and Romi (@DessRomaric). This credit
  is required by the license.
- **Music:** "Original music by Marllon Silva (xDeviruchi)". This credit is
  required by the license.
- **Sound effects:** original sounds made for this game. Retro 512 by Juhani
  Junkala (CC0). Interface Sounds by Kenney (CC0).
- **Fonts:** Kalam, Kaushan Script, DejaVu Sans, Noto Sans Tagalog (OFL).
- **AI disclosure (Form 03):** programming assisted by Claude (Anthropic). No
  AI-generated art, music or voices.
- **Inspiration** (for the synopsis): Baybayin learning games such as Likha!
  Mahika (UP Diliman), Learn Baybayin, and the Talinghaga card game. Credit
  the inspiration; do not copy their names, art or rule text.

---

## 12. Plan

| Day | Work | Status |
|---|---|---|
| **Day 1** | Word list, Baybayin keypad, Noto Sans Tagalog, server answer checking, monks; rename to Lakbayin | Done |
| **Day 2** | Procedural world (mirrored; monks, Monastery, fair spawns), per-team monk state, team vision on the minimap, carry/deposit, timer win, results screen, Practice mode; teacher mode and the old rules removed | Done. Live two-phone 1 v 1 verified Oct 23: keypad answers, carry, deposit, shared match end, and standings. Six-player custom tests verified Oct 23: normal walking, teammate updates, reconnect/carry recovery, timeout tie-break and Blue 10–6 finish |
| **Oct 25** | Record the trailer (1–2 min) and gameplay video (3–5 min, .mp4); Forms 01–03; synopsis (≤500 words); submit | |
| Before Nov 9 | Custom rooms, Watch mode, My Matches, global board, polish | Implemented and tested locally and live; six-player verification complete |
| Before Nov 26 | Playtests, balance (clock, monk count), word list review, art polish | |

Ship order if time runs short: practice mode and a working 3 v 3 match first.
Custom rooms, Watch mode and the boards can follow, since screening judges the
videos.

---

## 13. Decided
| Question | Decision |
|---|---|
| Name | **Lakbayin**: *lakbay* (journey) as a verb, "to travel or explore a place", ending in *-bayin* like Baybayin. Explore the world, write in Baybayin. No game or app found using it. |
| Match clock | **15 minutes**, including Practice |
| Results words | Filipino word and Baybayin spelling; no English meaning |
| Points per word | 1 per deposited word |
| Match end | Ends for everyone when a team finishes |
| Team size | 3 v 3 by default; one setting allows 1 v 1 through 5 v 5, with 1 v 1 for two-phone playtests |
| Matchmaking wait | Starts only when full; 90 s limit, then "No match found" and search again |
| Keypad labels | On in Practice, off in matchmade and custom games |
| Player characters | All 32 heroes for now |
| Minimap team vision | Yes: monks a teammate has seen show for the whole team |
| Word list | From trusted sources (§4.4) |
| Git history | Rewritten: the old documents are removed from every commit |

## 14. Open questions
1. **Balance after the full playtest:** review the 15-minute clock and
   10 monks with human players.
2. **Word-list review:** confirm spellings and meanings before recording.

The title screen, package id (`com.lakbayin.game`), and Baybayin tagline are
implemented. The display fonts remain Kaushan Script and Kalam.
