# Netcode and bandwidth-reduction techniques for a 40-player 2D classroom game

Context used for every estimate: NumXventure (Godot 4.6, Android), up to ~40 phones on one 2D map, non-competitive walking (steady speed toward a tap or joystick direction), transport = Supabase Realtime Broadcast, current "teacher hub" design (phones sample at 10 Hz, send a JSON bundle every 0.5 s with 0.3 s overlap to the teacher only; the teacher broadcasts one JSON snapshot of everyone 3x/s, ~2.6 KB at 30 players; phones play others ~1.0-1.2 s behind through an adaptive jitter buffer; ~165 msg/s at 30 players, 98% delivered). Everything under "Inferences" is my own arithmetic or judgement, not a published figure.

## 1. Snapshot interpolation vs state synchronization vs deterministic lockstep (Glenn Fiedler / Gaffer On Games): recommended delay and reported compression gains

### Takeaway
Fiedler's rule is to buffer enough to survive two lost packets in a row: about 3 send intervals plus 1-2 frames of jitter (350 ms at 10 packets/s). Applied to this project's 0.5 s uplink cadence, that rule fully explains the ~1 s delay. His compression series (quantization, then delta against an acked baseline, then bit-packing) cut a 900-cube scene from 17.37 Mbit/s to 256 kbit/s. Quantization alone cut per-object state from 321 bits to 80 bits (-75%).

### Cited Findings
- Snapshot interpolation delay rule: "the interpolation buffer should have enough delay so that I can lose two packets in a row and still have something to interpolate towards." — [Fiedler, Snapshot Interpolation](https://gafferongames.com/post/snapshot_interpolation/)
- For 2-5% packet loss at 10 packets/s, "the amount of delay that works best... is 3X the packet send rate. At 10 packets per-second this is 300ms", plus jitter of "typically only one or two frames @ 60fps", giving ~350 ms. (He means 3x the send *interval*.) — [Fiedler, Snapshot Interpolation](https://gafferongames.com/post/snapshot_interpolation/)
- Higher send rates shrink the delay: 30 snapshots/s gives ~150 ms and 60 packets/s needs only ~85 ms. — [Fiedler, Snapshot Interpolation](https://gafferongames.com/post/snapshot_interpolation/)
- Uncompressed example bandwidth: 25,342.5 bytes/packet × 60 packets/s = 1,520,550 B/s (11.6 Mbit/s), or ~2 Mbit/s at 10 packets/s. — [Fiedler, Snapshot Interpolation](https://gafferongames.com/post/snapshot_interpolation/)
- Extrapolation "doesn't work very well for rigid bodies because their motion is non-linear and unpredictable." — [Fiedler, Snapshot Interpolation](https://gafferongames.com/post/snapshot_interpolation/)
- Snapshot compression series, starting at 17.37 Mbit/s at 60 Hz, with 321 bits per cube (quaternion 128, velocity 96, position 96, 1 flag bit). — [Fiedler, Snapshot Compression](https://gafferongames.com/post/snapshot_compression/)
  - Orientation "smallest three": 128 bits → 29 bits. — same source
  - Position bounded to ±256 m horizontally and 0-32 m vertically at 512 values per metre (~2 mm): 96 bits → 50 bits (18/18/14). — same source
  - Velocity dropped entirely ("Linear interpolation is good enough at 60HZ"). Result: 80 bits (10 bytes) per cube after quantization. — same source
  - Delta against a baseline: an unchanged cube costs 1 bit. The steady state encodes "relative to a baseline that is roughly RTT in the past", and the receiver keeps acking "the most recent snapshot I have received is snapshot n" so the sender only uses baselines the receiver has. — same source
  - Changed-index list instead of a 901-bit changed mask: stationary-scene cost fell to ~15 kbit/s. Relative index encoding averaged 5.5 bits/index. Position deltas averaged 26.1 bits, and orientation deltas 23.3 bits. — same source
  - Final result: **256 kbit/s** (≈1.5% of the 17.37 Mbit/s start, a ~68x reduction). — same source
- State synchronization means sending "both input and state", with simulation on both sides. — [Fiedler, State Synchronization](https://gafferongames.com/post/state_synchronization/)
- Its priority accumulator is a per-object float array kept across frames. Each frame adds current priority, objects are sorted by accumulator, and the accumulator resets to zero for objects that fit in the packet while the rest keep theirs. The example caps a packet at 64 updates under a 256 kbit/s budget. — [Fiedler, State Synchronization](https://gafferongames.com/post/state_synchronization/)
- If both sides simulate, state must be quantized on both sides (4096 position values per metre, 15 bits per quaternion component). The jitter buffer holds "4-5 frames @ 60HZ". Visual smoothing of corrections blends with factor 0.95 for errors ≤25 cm and 0.85 for ≥1 m. — [Fiedler, State Synchronization](https://gafferongames.com/post/state_synchronization/)
- Deterministic lockstep sends "only the inputs... rather than the state". The example input is 6 bits/frame, so worst case 120 inputs = 90 bytes. All unacked inputs go redundantly in every UDP packet. "bandwidth is proportional to the size of the input, not the number of objects". It requires bit-exact determinism, which does "not necessarily" hold across compilers/OS/architectures, and a peer "has to wait" if an input is missing. — [Fiedler, Deterministic Lockstep](https://gafferongames.com/post/deterministic_lockstep/)

### Inferences
- The current hub is snapshot interpolation of sampled positions. The data for any one remote hero refreshes only at the uplink cadence (0.5 s). The 3 Hz downlink only re-carries it. Fiedler's 2-loss rule at a 0.5 s cadence gives ~1.5 s. The 0.3 s overlap (redundancy) lets a single lost bundle be partly covered, which is why the measured buffer of ~1.0-1.2 s sits nearer a "lose one" rule. With 0.33 s bundles, the same arithmetic gives ~0.7-1.0 s (measured 0.9 s). The measurements match the published rules, so the delay comes from the cadence and cannot be tuned away without changing it.
- Getting Fiedler-level delay (~350 ms) with interpolation alone needs ~10 Hz end to end. At 40 phones that is ~400 uplinks/s + 10 × 41 = 410 broadcast deliveries/s ≈ 810 msg/s, above Supabase's free quota (100 msg/s) and Pro quota (500 msg/s) ([Supabase quotas](https://supabase.com/docs/guides/realtime/quotas)). Low delay at this message budget therefore needs intent-based movement (sections 4, 5, 9), not faster snapshots.
- Lockstep is a poor fit: one slow or backgrounded phone stalls everyone (peers must wait for inputs), and Godot float physics across 40 different Android SoCs is not guaranteed bit-exact.

### Gaps
- Fiedler's "Networked Physics" GDC talk was not reviewed. The three articles above cover the same material.

## 2. Valve Source engine networking and Bernier's 2001 lag-compensation paper

### Takeaway
Source by default receives ~20 snapshots/s and renders other entities 100 ms in the past (2 snapshot intervals) "so even if one snapshot is lost, there are always two valid snapshots". It falls back to short linear extrapolation when more than one is lost. Snapshots are delta-compressed against the last acknowledged update. Lag compensation is irrelevant here because NumXventure has no hit detection.

### Cited Findings
Note: developer.valvesoftware.com returned HTTP 403 / a bot-check page to both WebFetch and curl. The quotes below come from search-engine excerpts of the page, not a full read.
- "By default, the client receives about 20 snapshots per second", i.e. one update about every 50 ms. — [Valve, Source Multiplayer Networking](https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking)
- "Source defaults to an interpolation period ('lerp') of 100-milliseconds (cl_interp 0.1); this way, even if one snapshot is lost, there are always two valid snapshots to interpolate between." — [Valve, Source Multiplayer Networking](https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking)
- "interpolation period = max( cl_interp, cl_interp_ratio / cl_updaterate )". You can lower the period by setting cl_interp 0 and raising cl_updaterate. — [Valve, Source Multiplayer Networking](https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking)
- "If more than one snapshot in a row is dropped... the renderer uses extrapolation (cl_extrapolate 1) and tries a simple linear extrapolation of entities based on their known history so far." — [Valve, Source Multiplayer Networking](https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking)
- Delta compression: the server sends "only changes (a delta snapshot) that happened since the last acknowledged update". Full snapshots are sent "only... when a game starts or a client suffers from heavy packet loss for a couple of seconds", and cl_fullupdate requests one. — [Valve, Source Multiplayer Networking](https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking) (via search excerpt)
- Yahn W. Bernier (Valve), "Latency Compensating Methods in Client/Server In-game Protocol Design and Optimization", GDC 2001. — [Valve Developer Community](https://developer.valvesoftware.com/wiki/Latency_Compensating_Methods_in_Client/Server_In-game_Protocol_Design_and_Optimization)

### Inferences
- Valve's rule (interp = 2 × snapshot interval, tolerate 1 loss) applied to the 0.5 s uplink cadence gives 1.0 s, which is what the project measured. To halve the delay with interpolation, halve the cadence, and the message count roughly doubles (see section 10).
- Valve's "extrapolate briefly when the buffer runs dry" is a cheap addition to the existing jitter buffer. It would let the buffer target 2 intervals instead of ~3 with little visible cost, because heroes walk in straight lines at constant speed.

### Gaps
- Could not verify the extrapolation cap (commonly cited as cl_extrapolate_amount 0.25 s), the default `rate` in bytes/s, or the cl_cmdrate default, because the page itself could not be fetched.
- Could not read Bernier's paper text (same bot check). Its title, author and GDC 2001 venue are verified only from search results. It mainly covers client prediction and server-side lag compensation (rewinding for hit detection), which does not apply to a game with no combat.

## 3. Overwatch (Tim Ford, GDC 2017; "Let's Talk Netcode" developer update)

### Takeaway
What can be verified publicly: a 16 ms fixed command frame (7 ms in tournament mode), a PC update-rate increase from ~21 Hz to ~60/63 Hz with interpolation delay falling from ~60 ms to ~20 ms, and an automatic fallback to the lower rate on connections that cannot keep up. The talk's details on input redundancy and time dilation reach me only through a secondary summary.

### Cited Findings
- The GDC 2017 session "'Overwatch' Gameplay Architecture and Netcode" by Timothy Ford (Blizzard) exists on GDC Vault. It covers the ECS architecture and how the networked simulation "leverages determinism". — [GDC Vault](https://gdcvault.com/play/1024001/-Overwatch-Gameplay-Architecture-and)
- Per a secondary write-up of the talk: "The simulation runs on fixed 16 milliseconds each... In tournament configuration, that drops to 7ms." When the server's input buffer starves, the client simulates slightly faster ("approximately 15.2ms" frames) to refill it. "the client bundles every input since the last server-acknowledged movement state into a single packet." — [Edgegap, Game Backend Deep Dive: Overwatch](https://edgegap.com/blog/game-backend-deep-dive-overwatch-2016-netcode-architecture-rollback)
- High-bandwidth update (PC): server updates went from "21 times per second" to "60 times per second". "the interpolation delay has typically hovered around 60ms. Now... closer to 20ms for many players". A "dynamic tool... will automatically return you to the old update rate" for connections that cannot handle it. Tim Ford: "you will be shot around corners less". — [GamesBeat](https://gamesbeat.com/overwatch-netcode-tick-rate-60hz/)
- Some coverage says 63 Hz rather than 60 Hz (search-result summaries of KitGuru and similar outlets). — [KitGuru](https://www.kitguru.net/?p=305704) vs [GamesBeat](https://gamesbeat.com/overwatch-netcode-tick-rate-60hz/)

### Inferences
- Two Overwatch patterns map onto this project. (a) Resending everything unacknowledged in each packet is what the 0.3 s overlap already does in a weaker form. (b) Adaptive rate on a bad line, which the project already does for answers ("hold actions on a bad line"). Overwatch-scale tick rates are irrelevant: a 40-phone Supabase budget is hundreds of messages per second in total, not 60 per second per player.

### Gaps
- The GDC talk and the developer-update video are not transcribed by any first-party source I could reach. The 16 ms/7 ms, 15.2 ms and input-bundling claims rest on one secondary summary (Edgegap) and are unverified against the video. The 60 vs 63 Hz figure conflicts between outlets.

## 4. Gabriel Gambetta, "Fast-Paced Multiplayer": entity interpolation vs dead reckoning

### Takeaway
Gambetta shows other players "in the past" by one server update interval (100 ms at 10 Hz) because shooter players "run, stop, and turn corners" unpredictably. Dead reckoning is better for predictable movers such as fast cars. A tap-to-walk hero (straight line, constant speed, known destination) is more predictable than either, so the destination itself can be sent.

### Cited Findings
- Dead reckoning works for cars: "if it's running at 100 meters per second, a second later it will be roughly 100 meters ahead". Position "is highly dependent on its previous position, speed and direction." — [Gambetta, Entity Interpolation](https://www.gabrielgambetta.com/entity-interpolation.html)
- It fails for shooters: "players usually run, stop, and turn corners at very high speeds, making dead reckoning essentially useless". — [Gambetta, Entity Interpolation](https://www.gabrielgambetta.com/entity-interpolation.html)
- Entity interpolation shows "the other players in the past relative to the user's player". With 10 Hz updates "you're always showing the user actual movement data, except you're showing it 100 ms 'late'." — [Gambetta, Entity Interpolation](https://www.gabrielgambetta.com/entity-interpolation.html)

### Inferences
- Interpolation was the right first choice for robustness: it never shows a wrong position and needs no shared navigation logic. But its cost is a delay of at least 1 update interval, or 2-3 with loss tolerance (Valve, Fiedler), and the project's interval is long (0.5 s).
- Dead reckoning or extrapolation is better when movement is smooth and predictable, updates are slow, and small transient errors are acceptable. All three hold here: no combat, steady speed, slow uplink. Pure tap-to-walk is the ideal case, where the receiver can know the *future* path, not just extrapolate it (section 9). Joystick movement sits between the two: dead reckoning with velocity is good while the stick is held steady and needs a correction on each turn.

### Gaps
- Gambetta's pages on client-side prediction and server reconciliation were not fetched. They concern the local player's own input latency, which this game avoids already because each phone moves its own hero locally.

## 5. Dead reckoning (DIS / IEEE 1278): send only when the predicted error exceeds a threshold

### Takeaway
DIS, which came out of DARPA's SIMNET tank simulators, has every node extrapolate each entity with an agreed algorithm. The owner sends a new Entity State PDU only when its own copy of the extrapolation drifts past a threshold, plus a heartbeat of at least one PDU every 5 s. For a hero walking a straight line at constant speed, this means about one message per turn or stop. I found no published "percent of updates saved" figure for walking avatars. The best published data compares prediction error, not message counts.

### Cited Findings
- DIS originated in DARPA SIMNET for networking tank simulators. Dead reckoning is its "technique for latency hiding and bandwidth reduction". The owner runs the same extrapolation as remote nodes and sends a new entity state PDU only "if the dead reckoning and true state values differ by an amount that exceeds the agreed-upon dead reckoning threshold". Otherwise PDUs go out "at a minimum of one every five seconds". — [Aronson, "Dead Reckoning: Latency Hiding for Networked Games", Gamasutra 1997 (archived copy)](https://www.comp.nus.edu.sg/~cs4344/0607s1/deadreckoning.pdf)
- Large thresholds give "noticeable jerkiness" on correction. Small thresholds "force more PDUs to be sent". DIS uses smoothing algorithms when correcting. There are nine standard algorithms: static, constant velocity, and velocity plus acceleration are the typical ones. — [Aronson 1997](https://www.comp.nus.edu.sg/~cs4344/0607s1/deadreckoning.pdf)
- "Predictive contracts" (DARPA ADS) extend dead reckoning. Example: "drive along road to waypoint", where the sender transmits once that it will drive down a road to a point, and peers need no further traffic unless it deviates. "if all the entities in a simulation behave unpredictably all the time, dead reckoning offers little gain." — [Aronson 1997](https://www.comp.nus.edu.sg/~cs4344/0607s1/deadreckoning.pdf)
- DIS dead-reckoning algorithms are specified in IEEE 1278.1-1995 Annex B (per a search-result excerpt; page not fetched). — [Open-DIS DIS_DeadReckoning javadoc](https://open-dis.sourceforge.net/javadoc/open-dis/docs/edu/nps/moves/deadreckoning/DIS_DeadReckoning.html)
- Pantel & Wolf (NetGames 2002) measured prediction error, not message savings. At 200 ms delay the best scheme left 25.6% residual deviation for a sports game, 16.1% for 3D action, and 6.1% for a racing simulator. For the simulator, deviations were "an order of magnitude smaller than without a prediction". Sports games are hardest because movement is not "continuous and smooth". — [Pantel & Wolf, "On the Suitability of Dead Reckoning Schemes for Games"](https://svn.sable.mcgill.ca/sable/courses/COMP763/oldpapers/pantel-02-suitability.pdf)

### Inferences
- Savings for steadily walking avatars, by construction: a constant-velocity hero on a straight leg has **zero** extrapolation error, so it costs 1 message per leg start, turn or stop, plus heartbeats. Example: a 5 s walk costs 10 bundles today (2/s) versus 2-3 messages with dead reckoning, about 75% fewer uplinks while walking. Idle heroes cost one heartbeat per 2-5 s instead of 2/s (90-96% fewer).
- Joystick play in "sports-game" style (frequent small direction changes) is the case Pantel & Wolf found hardest. Quantizing the stick to 8 or 16 directions and sending on direction change bounds the message rate. It needs to be measured with the project's existing walker simulation (game/tools/sim).
- Correction size at a turn ≈ speed × (one-way latency + hub hold). Smooth it with DIS-style smoothing or Fiedler's exponential blend instead of a snap.

### Gaps
- I found no published measurement of message reduction for pedestrian or avatar dead reckoning (only error metrics). The IEEE 1278.1 text itself is paywalled and was not read.

## 6. Interest management / area of interest

### Takeaway
Production engines (the Tribes "scope", Mirror spatial hashing, Unity NGO visibility, Godot visibility filters) all cull per connection on an authoritative server that sends different data to each client. On Supabase Broadcast, which bills 1 sent + 1 per receiver, per-viewer culling *raises* the message count even though it cuts bytes. It is not worth it for this hub at 40 players.

### Cited Findings
- Tribes "scope": the ghost manager "does not ghost all objects... but instead has a concept of 'scope'", meaning objects "potentially visible to a client", found with "a spatial database". In-scope objects get a priority from distance, projected radius, relative velocity, animation state and "interest modifiers". — [Frohnmayer & Gift, The TRIBES Engine Networking Model](https://www.gamedevs.org/uploads/tribes-networking-model.pdf)
- Mirror Spatial Hashing puts entities in a grid and sends each connection the entities in its cell and the 8 neighbouring cells. It was "30x faster than distance checking" in early uMMORPG tests (a CPU claim, not a bandwidth one). — [Mirror docs, Spatial Hashing](https://mirror-networking.gitbook.io/docs/manual/interest-management/spatial-hashing)
- Unity Netcode for GameObjects: `CheckObjectVisibility(clientId)` is evaluated by the server. `NetworkShow`/`NetworkHide` toggle per client. If unset, objects are visible to all. There is no built-in grid interest system on that page. — [Unity NGO, Object visibility](https://docs.unity3d.com/Packages/com.unity.netcode.gameobjects@2.4/manual/basics/object-visibility.html)
- Godot `MultiplayerSynchronizer`: `public_visibility`, `add_visibility_filter(callable(peer_id) -> bool)`, `set_visibility_for(peer, bool)` and `visibility_update_mode` give per-peer filtering. — [Godot docs, MultiplayerSynchronizer](https://docs.godotengine.org/en/stable/classes/class_multiplayersynchronizer.html)
- Supabase billing counts "one message sent plus one message per subscribed client that receives it": a broadcast heard by 4 clients = 5 messages. — [Supabase, Realtime messages usage](https://supabase.com/docs/guides/platform/manage-your-usage/realtime-messages)

### Inferences
- Message arithmetic at 40 phones and 3 Hz:
  - One broadcast snapshot costs 3 × (1 + 40) = 123 msg/s.
  - Per-viewer culled snapshots on private topics cost 3 × 40 × (1 + 1) = 240 msg/s, about double.
  - Bytes fall by the off-screen fraction. If the screen shows ~1/4 of the map and heroes are spread evenly, about 70-75% fewer bytes after an edge margin. If heroes cluster (e.g. around the same quiz station), the saving is much smaller.
  - Region channels (Mirror-style cells as Supabase topics) cost ≥1 send per occupied cell per tick, plus 1 receive per subscribed cell per phone. Each phone typically needs 2-4 cells, so deliveries also exceed one broadcast.
- Culling only pays off with a relay that is billed by bandwidth rather than per message, such as the teacher device or a small WebSocket/ENet server unicasting to each phone. In that setup, Godot's visibility filters or a 3×3 grid would cut bytes and the client-side interpolation CPU by the off-screen fraction.
- Team-based filtering (own team of 5 at full rate, others coarser) only makes sense if gameplay wants it. Under Supabase billing it has the same message problem as per-viewer culling.
- A cheap local win independent of the network: skip interpolating and animating off-screen heroes on each phone (CPU and battery, not bandwidth).

### Gaps
- SpatialOS and Photon interest-management docs were not reviewed.

## 7. Delta compression, quantization, binary vs JSON, batching

### Takeaway
In Fiedler's example, quantization plus binary bit-packing gives ~4x and delta encoding another large step. Here, packing the ~87 B/player JSON snapshot entry into ~6-15 bytes would cut snapshot bytes by roughly 85-93%. Under Supabase's per-message billing this saves no counted messages. It saves phone data, Wi-Fi airtime and JSON parse time. Batching, which the hub already does, is the lever that cut messages.

### Cited Findings
- Quantization in Fiedler's example: 321 → 80 bits per object. With delta and index encoding, the total went from 17.37 Mbit/s to 256 kbit/s. — [Fiedler, Snapshot Compression](https://gafferongames.com/post/snapshot_compression/)
- Delta encoding needs acked baselines: the receiver keeps acking its newest snapshot, and the sender encodes against "a baseline that is roughly RTT in the past". — [Fiedler, Snapshot Compression](https://gafferongames.com/post/snapshot_compression/)
- Source sends delta snapshots against the last acknowledged update and full snapshots only at start or after heavy loss. — [Valve, Source Multiplayer Networking](https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking) (via search excerpt)
- Tribes bit-packs everything: "All packet data, including the header... transmitted using the smallest number of bits possible". Example: `writeBool` = 1 bit, a 2-bit damage state. Ack overhead is 3 bytes per packet. — [Frohnmayer & Gift](https://www.gamedevs.org/uploads/tribes-networking-model.pdf)
- Tribes partial updates: each object has a state mask of 20+ flags, and only dirty state groups are sent. — [Frohnmayer & Gift](https://www.gamedevs.org/uploads/tribes-networking-model.pdf)
- Age of Empires: sending "X and Y coordinates, status, action, facing and damage would limit us to 250 moving units", hence commands instead of state. — [Bettner & Terrano, 1500 Archers on a 28.8](https://www.gamedeveloper.com/programming/1500-archers-on-a-28-8-network-programming-in-age-of-empires-and-beyond)
- Godot 4 `PackedByteArray` has `encode_u16`/`decode_u16`, `encode_s8`, `encode_half`, `encode_float`, and `compress()`/`decompress()`. — [Godot docs, PackedByteArray](https://docs.godotengine.org/en/stable/classes/class_packedbytearray.html)
- Godot `MultiplayerSynchronizer` exposes `replication_interval` (for REPLICATION_MODE_ALWAYS) and `delta_interval` (for REPLICATION_MODE_ON_CHANGE). This is Godot's built-in on-change delta sync, available only over Godot's own multiplayer peers, not Supabase. — [Godot docs, MultiplayerSynchronizer](https://docs.godotengine.org/en/stable/classes/class_multiplayersynchronizer.html)
- The Supabase Broadcast payload limit is 256 KB (Free) and 3,000 KB (Pro). — [Supabase quotas](https://supabase.com/docs/guides/realtime/quotas)

### Inferences
- Bytes per player:
  - JSON as measured: 2.6 KB / 30 ≈ **87 B/player**.
  - Packed binary: id u8 (1) + x u16 (2) + y u16 (2) + state/facing u8 (1) = **6 B**. With a short path tail of 3 extra 0.1 s samples as int8 dx/dy deltas (2 B each), **~12 B**. Base64 inside a JSON broadcast adds a third, giving 8-16 B.
  - That is 82-93% smaller. A 40-player snapshot goes from ~3.5 KB to ~0.3-0.65 KB.
  - u16 pixels cover maps up to 65,535 px. Quarter-pixel units fit if the map is under 16,384 px. Tile units are coarser and risk visible stepping.
- Downlink bytes, at 3 broadcasts/s × N receivers:
  - Now: ~234 KB/s total (~7.8 KB/s per phone) at 30 players, and ~420 KB/s (~10.4 KB/s per phone) at 40.
  - Packed: ~25-50 KB/s total at 40 players (≤1.3 KB/s per phone).
  - Counted messages do not change.
- Changed-only snapshots (each entry included only if the hero moved since the last broadcast, plus a full keyframe every ~2 s so a missed message heals itself) remove idle heroes from the payload. Bytes scale with the moving fraction m (m = 0.3 saves a further ~70%). This avoids per-viewer acks, which Fiedler-style baseline deltas would need and which do not fit a single broadcast to 40 viewers.
- Supabase counts messages, not bytes. So the meaningful "batching" is fewer broadcasts and uplinks per second, not smaller ones. The hub's move from many-to-many (~11,000 deliveries/s) to N-to-1-to-N (~165 msg/s) was the batching win, and it is already done.

### Gaps
- I did not verify whether Supabase Realtime accepts raw binary Broadcast payloads (if not, base64 inside JSON is needed). Real uplink bundle sizes were not available, so the uplink byte figures (~200-300 B JSON per bundle) are an assumption.

## 8. Adaptive send rates and priority accumulators (Fiedler, Tribes)

### Takeaway
Send nothing (or a slow heartbeat) when a hero is idle and send on change when it moves. Priority accumulators and Tribes-style scope priority share a fixed bandwidth budget fairly across many objects. They matter when a packet cannot hold everything, which is not the case here: the snapshot is ~3.5 KB against a 256 KB limit. Idle suppression is the big win, because classroom play alternates walking with answering questions.

### Cited Findings
- Fiedler's priority accumulator (per-object accumulated priority, sorted, reset when sent) is used to fit the most important updates under a budget of 64 updates per packet at 256 kbit/s. — [Fiedler, State Synchronization](https://gafferongames.com/post/state_synchronization/)
- Tribes: the Stream manager sets a per-connection packet rate and size. A 28.8 modem client "could set a rate of 10 packets per second with a size of 200 to produce about 2K of data per second". Objects with non-zero state masks are ordered by status change, then priority, and written until the packet is full. — [Frohnmayer & Gift](https://www.gamedevs.org/uploads/tribes-networking-model.pdf)
- Tribes "Most Recent State": lost state is re-sent only if no later packet already carried a newer version of that state bit. — [Frohnmayer & Gift](https://www.gamedevs.org/uploads/tribes-networking-model.pdf)
- Tribes moves: collected every 32 ms and each sent 3 times in consecutive packets. Sending every unacked move caused a "negative feedback loop" on low-bandwidth links, because bigger packets after a drop caused more drops. — [Frohnmayer & Gift](https://www.gamedevs.org/uploads/tribes-networking-model.pdf)
- Tribes supported up to 128 players and "low end modem connections". — [Frohnmayer & Gift](https://www.gamedevs.org/uploads/tribes-networking-model.pdf)
- Overwatch automatically drops back to the lower update rate on connections that cannot sustain the high one. — [GamesBeat](https://gamesbeat.com/overwatch-netcode-tick-rate-60hz/)
- DIS heartbeat: at least one PDU every 5 s even without changes. — [Aronson 1997](https://www.comp.nus.edu.sg/~cs4344/0607s1/deadreckoning.pdf)

### Inferences
- Idle uplink suppression at 40 phones: when a hero is stationary, send one "stopped at (x,y)" message and then a heartbeat every ~5 s (0.2 msg/s).
  - With a moving fraction m = 0.3: uplink ≈ 40 × 0.3 × 2 + 40 × 0.7 × 0.2 ≈ 24 + 6 = 30 msg/s vs 80 (-63% uplink, about -25% of the ~203 total).
  - In a pure quiz phase (m ≈ 0): uplink ≈ 8 msg/s.
- Idle downlink suppression: the hub skips a broadcast when nothing changed and sends a keyframe every ~2-5 s. In a quiz phase this cuts 123 msg/s to ~8-20 msg/s, so the total falls from ~203 to ~20-30 msg/s (about -85-90%).
- Tribes' negative feedback loop is a warning for the current "resend 0.3 s of overlap" design on weak Wi-Fi. The overlap is bounded, which is good; it should stay bounded and not grow after losses.
- A priority accumulator is not needed at this scale (the whole snapshot fits easily). It becomes relevant only with per-viewer rate limits on a self-hosted relay.

### Gaps
- No published data on the walking vs idle duty cycle in classroom games. The m values above are placeholders to replace with the project's own telemetry or simulation.

## 9. Movement-specific tricks: send waypoints or tap destinations (intent) instead of positions

### Takeaway
Click-to-move games and RTS lockstep send *commands* (destination, path, order) and let every client simulate the walk. Age of Empires ran 1500 units on 28.8 modems this way. For tap-to-walk heroes this removes the deep jitter buffer: the receiver knows the whole future path, so a late message only shifts *when* it learns of a leg, not where the hero is during it. The main risks are desync when collision or pathfinding differ between devices, and lost command messages.

### Cited Findings
- Age of Empires sent only player commands and ran identical simulations everywhere. Commands issued in turn 1000 executed in turn 1002 (2 turns of buffer). Turns were typically 200 ms. The target was a 28.8 modem on a Pentium 90. — [Bettner & Terrano, 1500 Archers on a 28.8](https://www.gamedeveloper.com/programming/1500-archers-on-a-28-8-network-programming-in-age-of-empires-and-beyond)
- Latency tolerance from AoE user testing: "250 milliseconds of command latency was not even noticed—between 250 and 500 msec was very playable, and beyond 500 it started to be noticeable." Consistent latency mattered more than low latency. — [1500 Archers](https://www.gamedeveloper.com/programming/1500-archers-on-a-28-8-network-programming-in-age-of-empires-and-beyond)
- Desync danger: "A deer slightly out of alignment when the random map was created would forage slightly differently—and minutes later a villager would path a tiny bit off". The team checksummed world objects, pathfinding and targeting. — [1500 Archers](https://www.gamedeveloper.com/programming/1500-archers-on-a-28-8-network-programming-in-age-of-empires-and-beyond)
- Westward (an open-source browser MMO): "the path is computed client-side and sent to the server. The client starts moving immediately along the computed path." Other clients "receive the path and play it". "The server doesn't send regular position updates about the players, it only communicates new paths". The trade-off: others see movement "a bit later", acceptable because "the gameplay doesn't rely on knowing the location of other players accurately". — [Westward wiki, Movement system](https://github.com/Jerenaux/westward/wiki/Movement-system)
- The DIS/ADS "predictive contract" "drive along road to waypoint" needs one message unless the entity deviates. — [Aronson 1997](https://www.comp.nus.edu.sg/~cs4344/0607s1/deadreckoning.pdf)
- A gamedev.net MMO movement thread describes sending only the destination point ("L2-style") with clients re-pathing locally, versus sending the route actually walked so clients need not re-run pathfinding. This is from a search-result excerpt only; the page returned 403. — [gamedev.net, MMO movement system](https://gamedev.net/forums/topic/710824-mmo-movement-system)
- Tribes ghost objects carry only state "needed to render the object, or to reasonably predict its motion". — [Frohnmayer & Gift](https://www.gamedevs.org/uploads/tribes-networking-model.pdf)

### Inferences
- Recommended message shape for a tap: `{id, seq, t0 (shared clock), speed, polyline [start, corners..., end]}`, with the polyline computed by the walker's phone. Sending the path rather than only the destination avoids re-pathing differences, which is the AoE/L2 desync risk. Binary size is ~4 B per point plus a header, ~15-30 B in total.
- Joystick mode: send `{pos, dir (quantized), t0}` on direction change. This is dead reckoning, and it is exact while the stick is held.
- Delay effect: a receiver gets a leg ~(hub hold 0-0.33 s + 2 hops) after it starts, then places the hero at `start + speed × (now − t0)` along the polyline. It catches up with the existing speed-up logic instead of jumping. The hero is therefore at the true position for the rest of the leg, and the visible lag shrinks from ~1.0-1.2 s all the time to ~0.2-0.5 s at the start of a leg only. That falls in AoE's "not noticed / very playable" band. This needs a clock offset per phone; the teacher hub's timestamps can supply it.
- Message estimate at 40 phones (assumptions: 50% walking, 0.5 taps or turns/s each, heartbeat every 5 s):
  - Uplink ≈ 10 + 8 = ~18 msg/s vs 80.
  - Downlink: the hub keeps ≤3 Hz batches and skips empty ticks, so ≤123 msg/s while anyone moves.
  - Total ≲140 msg/s vs ~203 (-30%) during play, ~20-30 msg/s during quiz phases, and payloads under ~1 KB.
  - Relaying each tap as its own broadcast would cost 41 messages per tap (~820 msg/s at 20 taps/s), so the hub must keep batching.
- Failure modes and mitigations:
  - Collision, pathfinding or wall-sliding differences between devices: mitigate by sending the walked polyline and a periodic position heartbeat (DIS-style), with smooth correction.
  - A lost leg message leaves the hero stalled or walking the old leg until the next heartbeat. Include the current leg (seq) in every heartbeat or snapshot, per Tribes' "most recent state" and Overwatch's resending of unacknowledged data.
  - Taps that change direction faster than the hub tick: only the latest leg matters.
  - Clock skew: send t0 relative to the hub clock.

### Gaps
- No first-party MMO engineering source with measured savings for click-to-move (Westward and forum threads are illustrative, not measured). AoE's latency thresholds concern a player's own commands in an RTS. Treating them as a tolerance for watching *other* players is my extrapolation.

## 10. Per-technique estimate for this setup: reduction, solo-dev GDScript complexity, failure modes

### Takeaway
Supabase counts 1 send + N receives per broadcast, so the message budget is set by how many broadcasts and uplinks per second there are, not by payload size. The biggest wins:
- Delay: send intent (tap path or velocity) instead of sampled positions.
- Messages: suppress idle uplinks and empty broadcasts.
- Bytes: binary quantized payloads.

Per-viewer interest management raises the message count on Supabase.

### Cited Findings
- Billing: "one message sent plus one message per subscribed client that receives it". — [Supabase, Realtime messages usage](https://supabase.com/docs/guides/platform/manage-your-usage/realtime-messages)
- Quotas: Free = 200 concurrent connections, 100 msg/s, 100 channel joins/s, 256 KB Broadcast payload. Pro = 500 connections, 500 msg/s, 3,000 KB payload. — [Supabase quotas](https://supabase.com/docs/guides/realtime/quotas)
- Published delay rules: Valve 2 × interval (tolerate 1 loss) — [Valve](https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking). Fiedler 3 × interval + jitter (tolerate 2 losses) — [Gaffer On Games](https://gafferongames.com/post/snapshot_interpolation/). Gambetta 1 × interval in his idealized example — [Gambetta](https://www.gabrielgambetta.com/entity-interpolation.html).

### Inferences
Baseline model (my decomposition of the project's numbers; "msg/s" = uplink sends + broadcast sends + broadcast receipts):
- 30 phones: uplink 30 × 2 = 60. Downlink 3 × (1 + 30) = 93. Sum ≈ 153 plus answers and presence ≈ the measured ~165.
- 40 phones: 80 + 3 × 41 = 123, about **203 msg/s** plus extras.
- Downlink bytes ≈ 87 B × N × 3 × N: ~234 KB/s at 30 and ~420 KB/s at 40. This is O(N²) because both snapshot size and receivers grow with N.
- Note: ~165-215 msg/s already exceeds the documented Free quota of 100 msg/s. Either the project is on a higher plan, or the free limit is enforced differently than the table suggests. Worth checking before relying on the free tier.

| Technique | Msg/s at 40 (vs ~203) | Bytes/s | Delay effect | GDScript complexity (solo) | Main failure modes |
|---|---|---|---|---|---|
| Shorter jitter buffer (Valve 2-interval rule) + brief linear extrapolation when dry | 0 | 0 | ~-0.1 to -0.3 s | Low (tune existing buffer) | Overshoot then correction on a turn during a double loss |
| Faster cadence (bundles 0.25 s, snapshots 5 Hz) | +~150 (≈80→160 up, 123→205 down) | +~70% | to ~0.6-0.7 s | Trivial (constants) | Busts Free/Pro quotas; more Wi-Fi contention |
| Binary + quantized payload (u16 x/y, u8 id, int8 deltas, base64) | 0 | -82 to -93% | none (slightly faster parse) | Low-medium (`PackedByteArray.encode_*`) | Version skew between app builds; base64 overhead; coarse units cause visible stepping |
| Changed-only snapshot + keyframe every ~2 s | 0 (or fewer if empty ticks skipped) | further -(1-m), e.g. -70% at m = 0.3 | none | Low | Missed keyframe leaves a hero stale for ≤2 s |
| Idle suppression (uplink heartbeat 0.2/s; skip empty broadcasts) | play m = 0.3: ~-50 (≈-25%); quiz phase: ~-180 (≈-85-90%) | similar fraction | none | Low | A "stopped" message lost leaves a ghost walking until the heartbeat; needs a stop flag in heartbeats |
| Dead reckoning (pos + vel, threshold, heartbeat) | uplink ~80 → ~15-25; downlink unchanged at 3 Hz | uplink -70-80% | remote shown at ≈ "now", error only at turns | Medium | Snap on turns (≈ speed × latency); joystick jitter → many sends; needs smoothing |
| Waypoint / tap path (predictive contract) + hub batching ≤3 Hz | ≲140 in play, ~20-30 in quiz | -90%+ | constant ~1.1 s lag → ~0.2-0.5 s at leg start only | Medium (shared clock, polyline playback, seq/heartbeat) | Desync if collisions/pathing differ (send the polyline, heartbeat-correct); lost leg (resend current leg in heartbeat); clock skew |
| Per-viewer interest management on Supabase | +~117 (123 → 240 downlink) | -50-75% (depends on clustering) | none | Medium-high | Pop-in at screen edges; more messages; only sensible on a self-hosted unicast relay |
| Priority accumulator | 0 | 0 at this scale | none | Medium | Unnecessary while a snapshot ≪ 256 KB |
| Deterministic lockstep | uplink tiny, but stalls | tiny | adds input delay; everyone waits for the slowest phone | High | Cross-device float non-determinism; one paused phone freezes all |

- Combined lazy path, in order of value per effort:
  1. Idle suppression on both legs (biggest message cut, smallest code).
  2. Tap-path / velocity intent for movement (biggest delay cut).
  3. Binary payload, only if phone data or parse time matters.

  With all three at 40 phones: ~120-140 msg/s while walking, ~20-30 msg/s during questions, ~1 KB/s per phone, and a visible lag of a few hundred ms at the start of each leg instead of ~1.1 s all the time.

### Gaps
- Tap rate, joystick direction-change rate and the walking/idle duty cycle in real lessons are unknown. All msg/s figures above scale linearly with them and should be re-run in the project's sim (game/tools/sim) with recorded inputs.
- Supabase does not document whether per-subscriber receipts on the teacher-only uplink channel count as 1 or more, beyond the general "1 sent + 1 per receiver" rule. The uplink was counted as 1 per bundle above to match the measured ~165 msg/s.
