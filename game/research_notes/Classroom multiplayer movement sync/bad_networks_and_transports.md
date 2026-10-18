# Bad school Wi-Fi, mobile data, and transports for a 40-phone Godot 4 classroom game

Context: NumXventure (Godot 4.6, Android phones such as the Realme RMX1851 on Android 11, a Windows teacher laptop), up to about 40 phones on one live 2D map, all live traffic on Supabase Realtime (Phoenix channels over wss:// on 443). The app already has a 5 s heartbeat, a 15 s stall rule, auto-reconnect, a 12 s HTTP timeout, scoring retries, good/weak/offline line states, and a ~1 s jitter buffer.
Research date: 2026-10-08. Older or second-hand figures are flagged where they appear. "Search snippet" means the claim came from a search-result summary because the page itself refused the fetch (HTTP 403).

## Q1. TCP/WebSocket head-of-line blocking at 1-5% loss: is it acceptable for 2-10 Hz position updates with a ~1 s playback buffer?

### Takeaway
TCP holds back every later byte until a lost segment is resent, so on a WebSocket each loss shows up as a stall of at least one round trip, often two, or a retransmission timeout (RTO) of 200 ms or more on Linux/Android. If the same segment is lost twice, the stall doubles. For slow, non-competitive movement shown ~1 s behind, a single loss is hidden by the buffer. Back-to-back losses of the same segment, which happen more often near 5% loss, can push past 1 s and show as a short freeze followed by a catch-up. That is acceptable for this game but not invisible.

### Cited Findings
- With TCP, when a packet is lost "you cannot access it until that lost packet has been retransmitted". Detecting a loss takes "at least round trip latency ... but commonly it takes 2*RTT". At 125 ms ping that is a 250 ms+ wait. Article dated Oct 1, 2008 (old, but the protocol behaviour is unchanged). — [Gaffer On Games, UDP vs. TCP](https://gafferongames.com/post/udp_vs_tcp/)
- Gaffer's reasoning: for many parts of a game "it really doesn't matter what happened a second ago, the game only cares about the most recent data", so reliable in-order delivery wastes time on stale data. — [Gaffer On Games](https://gafferongames.com/post/udp_vs_tcp/)
- Gaffer advises against mixing TCP and UDP because "TCP tends to induce packet loss in UDP packets". Build any reliability you need on top of UDP instead. — [Gaffer On Games](https://gafferongames.com/post/udp_vs_tcp/)
- RFC 6298: "Whenever RTO is computed, if it is less than 1 second, then the RTO SHOULD be rounded up to 1 second". The initial RTO is 1 s. When the timer expires the host "MUST set RTO <- RTO * 2". Any maximum RTO must be at least 60 s. — [RFC 6298](https://www.rfc-editor.org/rfc/rfc6298)
- Linux ignores the RFC's 1 s floor and uses a 200 ms minimum RTO (`#define TCP_RTO_MIN ((unsigned)(HZ/5))`). A 1 s minimum was shown to badly hurt throughput at about 1% loss. FreeBSD's minimum is 30 ms. — [netdev mailing list, 2010](https://lists.openwall.net/netdev/2010/06/04/6); [end2end-interest, "Minimum RTO values", 2004](https://mailman.postel.org/pipermail/end2end-interest/2004-November/004399.html) (old threads, Linux default still 200 ms to my knowledge; Android uses the Linux TCP stack)
- Measurement: a project streamed 2,500 coordinates from server to client over WebSocket, WebRTC DataChannel and WebTransport at 0% and 15% loss. At 15% loss, WebSocket "performance start[s] to suffer due to TCP head-of-line blocking". WebTransport stayed "very stable and efficient". Reliable WebRTC showed "sender-side head-of-line blocking". No date given, and 15% loss is far worse than the 1-5% asked about. — [Sh3b0/realtime-web (GitHub)](https://github.com/Sh3b0/realtime-web)
- One blog says a single loss on a WebSocket, with "1% loss rate ... common on mobile networks", adds 100-200 ms latency spikes. This is a vendor blog, not a measurement. Treat it as an illustration only. — [videosdk.live, WebSocket vs WebRTC DataChannel](https://videosdk.live/developer-hub/webrtc/websocket-vs-webrtc-datachannel)

### Inferences
- Rough stall sizes at 2-10 Hz with small messages. Fast retransmit needs later packets to arrive and trigger duplicate ACKs. At 10 Hz there are 100 ms gaps between sends; at 2 Hz there are 500 ms gaps. At low send rates, recovery therefore usually waits for the RTO: at least 200 ms plus the RTT-based term on Android. Expect a 250-600 ms stall per lost segment on a 50-150 ms RTT path. A ~1 s buffer absorbs that.
- A double loss (the retransmission is also lost) waits about RTO + 2xRTO, roughly 0.6-1.8 s, which goes past the 1 s buffer. At independent 5% loss, about 0.25% of segments hit this (5% x 5%); at 1% loss, about 0.01%. On a phone sending at 5 Hz, that is a visible freeze roughly every minute or two at 5% loss and rarely at 1%. Real Wi-Fi loss comes in bursts, which makes this worse than the independent-loss estimate.
- The stall delays the whole socket, not only position messages. Answer submissions and teacher events on the same WebSocket wait behind the lost segment too. They are still delivered in order and never dropped, which suits answers.
- After a stall, TCP delivers the queued backlog at once. The jitter buffer should snap to the newest position per player rather than replay every stale sample. This is the "only the latest matters" point from Gaffer.
- Verdict for this game: WebSocket head-of-line blocking is acceptable for non-competitive 2-10 Hz movement with ~1 s playback delay. The app's existing weak-line handling (halve or hold sends) also reduces bytes in flight and keeps queues short.

### Gaps
- I found no published 2024-2026 measurement of WebSocket stall length on Android at exactly 1-5% loss.
- Not verified this session: whether Android kernels change the 200 ms TCP_RTO_MIN, and how much Linux tail-loss probe (TLP) and RACK shorten recovery for sparse traffic. Both would make stalls shorter than the RTO estimate above.

## Q2. UDP options in Godot 4 on Android: ENet, PacketPeerUDP, WebRTC, WebTransport. Which need plugins, signalling or TURN, and what does TURN cost?

### Takeaway
WebSocketPeer, ENetMultiplayerPeer (UDP-only) and PacketPeerUDP ship with Godot and work in an Android export without plugins. WebRTC on Android needs the separate `webrtc-native` GDExtension plus a signalling server, and in practice STUN/TURN. I found no WebTransport support in Godot. ENet and raw UDP need a reachable UDP server (a public host or the teacher laptop on the same LAN), so they can't cross carrier-grade NAT or networks that block UDP without extra infrastructure. TURN is cheap at this game's data rates (Cloudflare charges $0.05/GB after 1,000 GB free per month).

### Cited Findings
- WebSocketPeer is an RFC 6455 WebSocket client/peer. It has `heartbeat_interval` (default 0, which sends no pings; not supported on Web), `inbound_buffer_size` and `outbound_buffer_size` (default 65535 bytes each), and `max_queued_packets` (default 4096). TLS options are set through `connect_to_url(..., tls_client_options)`. The fetch summary also states that it is built in on all platforms including Android. — [Godot docs, WebSocketPeer](https://docs.godotengine.org/en/stable/classes/class_websocketpeer.html)
- ENetMultiplayerPeer: "ENet only uses UDP, not TCP. When forwarding the server port ... you only need to forward the server port in UDP." `create_server()` defaults to `max_clients = 32` (up to 4095). Client and server creation take a `channel_count` for ENet channels. — [Godot docs, ENetMultiplayerPeer](https://docs.godotengine.org/en/stable/classes/class_enetmultiplayerpeer.html)
- WebRTC classes "are available automatically in HTML5, but require an external GDExtension plugin on native (non-HTML5) platforms". A signalling server is needed to exchange SDP before peers can talk. WebRTC also relies on ICE, DTLS and SDP. — [Godot docs, WebRTC tutorial](https://docs.godotengine.org/en/stable/tutorials/networking/webrtc.html)
- The official `godotengine/webrtc-native` GDExtension lists windows, linux, osx, android and ios. Binaries come from GitHub Releases. The repo page did not show the current release number or the Android ABIs. — [github.com/godotengine/webrtc-native](https://github.com/godotengine/webrtc-native)
- WebTransport is an IETF draft (draft-ietf-webtrans-http3-15, March 2026). It is not a finished RFC. — [IETF draft-ietf-webtrans-http3-15](https://www.ietf.org/archive/id/draft-ietf-webtrans-http3-15.html)
- Cloudflare Realtime TURN costs $0.05 per GB of egress. The first 1,000 GB per month is free and shared with the SFU. TURN is free when used with the Cloudflare SFU (search snippet of Cloudflare docs). — [Cloudflare Realtime TURN docs](https://developers.cloudflare.com/realtime/turn/index.md); [Cloudflare Realtime SFU pricing](https://developers.cloudflare.com/realtime/sfu/platform/pricing/)
- Zoom lists UDP 3478 as used "for Traversal Using Relays around NAT (TURN) support", which shows commercial real-time products run their own TURN. — [Zoom firewall rules](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0060548)

### Inferences
- ENet's default `max_clients = 32` is below the 40-phone target, so `create_server(port, 48)` or similar would be needed.
- ENet or PacketPeerUDP with the teacher laptop as server only works if phones can reach the laptop over UDP on the LAN. AP client isolation (Q3) and Windows Firewall can both block that. Phones on mobile data can't reach a laptop behind school NAT at all. This matches why the LAN-classroom spike was parked.
- With WebRTC, every phone behind CGNAT or strict school NAT would fall back to TURN. TURN cost for this game is small. Back-of-envelope: a star topology at 10 Hz, 40 recipients, about 550 B per batched snapshot, comes to about 220 KB/s, or roughly 0.8-0.9 GB per class hour. That fits inside Cloudflare's 1,000 GB free tier unless usage is very heavy. The real cost is complexity: a GDExtension per ABI, a signalling server, and ICE debugging.
- Only WebSocket reuses the existing Supabase stack with no new server.

### Gaps
- Not fetched this session: the PacketPeerUDP docs page ([class_packetpeerudp](https://docs.godotengine.org/en/stable/classes/class_packetpeerudp.html)). It is part of the core engine to my knowledge, but this is unverified here.
- I found no Godot proposal or plugin for WebTransport or QUIC. The search returned only IETF drafts.
- Not checked: the latest `webrtc-native` release version and date, whether it supports Godot 4.6, and Android armv7 support (the RMX1851 is arm64-capable). Twilio's TURN price was not checked.

## Q3. School and enterprise network policies: blocked UDP or non-443 ports, client/AP isolation, captive portals, content filters that break WebSockets

### Takeaway
Classroom and real-time vendors assume school networks may block UDP and non-standard ports, close long-lived connections, or break TLS through inspection. They ship over TCP/443 WebSocket and ask IT to allow-list domains and skip SSL inspection. Media apps (Meet, Zoom) prefer UDP but fall back to TCP/443 with lower quality, while Discord voice simply fails without UDP. Client isolation stops phones talking to each other or to the teacher laptop over the LAN.

### Cited Findings
- Google Meet: "For audio and video, set up outbound UDP ports 3478 and 19302–19309." "If UDP ports are blocked, TCP will be used. Use of TCP or proxied TCP can decrease overall meeting quality." Also: "Best practice is not to use proxy servers for Meet traffic. Proxying traffic adds latency." — [Google Workspace Admin, Prepare your network for Meet](https://knowledge.workspace.google.com/admin/meet/prepare-your-network-for-meet-meetings-and-live-streams)
- Zoom lists UDP 3478, 3479 and 8801-8810 for meetings and UDP 443 for clients and its CDN (HTTP/3). The fetched page did not describe TCP fallback. — [Zoom firewall rules](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0060548)
- Discord's troubleshooting says work and school networks may block Discord, and that it only works on VPNs that support UDP. Text works while voice hangs on "RTC Connecting"/"No Route" (search snippet). — [Discord Support, voice connection errors](https://support.discord.com/hc/en-us/articles/115001310031)
- Kahoot: "Some firewalls, antivirus, and network monitoring tools automatically close connections if they remain open". Networks that inspect SSL "sometimes replace Kahoot's certificates with their own, which can cause authentication errors", so its URLs may need to bypass monitoring (search snippet; page returned 403). — [Kahoot Support, How to avoid connectivity issues](https://support.kahoot.com/hc/en-us/articles/115003198708-How-to-avoid-connectivity-issues)
- Gimkit asks schools to allow `*.gimkitconnect.com` on ports 80/443, permit WebSockets, and exclude it from SSL inspection, with a check page at gimkit.com/check. This comes from a third-party blog, not Gimkit's own page. — [coopboardgames.com, Troubleshooting Gimkit game servers](https://coopboardgames.com/online-gaming/troubleshooting-in-gimkit-game-servers/)
- Blooket: school firewalls blocking the WebSocket protocol are the main cause of "WebSocket error". Schools commonly use iBoss or Lightspeed filters. Source is a third-party 2026 guide (low authority). — [axeetech, Blooket WebSocket error fix](https://axeetech.com/blooket-websocket-error/)
- UniFi "Client Device Isolation" stops devices on the same AP from talking to each other. It only applies per AP, and guest/hotspot setups block access to the internal LAN. Source is a third-party UniFi guide. — [unihosted, UniFi guest Wi-Fi](https://www.unihosted.com/blog/how-to-set-up-a-unifi-guest-wifi-network-with-or-without-a-unifi-gateway); [homenetworkguy, UniFi guest control blocks local services](https://homenetworkguy.com/not-to/unifi-enabling-guest-control-blocked-local-services-by-default/)

### Inferences
- wss:// on 443 to a big cloud domain (supabase.co) is the most likely transport to get through an unknown Philippine school network. UDP to arbitrary ports, and LAN peer-to-peer, are the most likely to be blocked.
- The two remaining WebSocket risks are SSL inspection (it breaks certificate checks in Godot's TLS) and firewalls that close idle long-lived connections. The app's 5 s heartbeat keeps the connection from going idle. For SSL inspection, the fix is a teacher/IT checklist: allow-list `*.supabase.co` and skip inspection for it, plus an in-app "network check" screen like gimkit.com/check or quizizz.com/check.
- Captive portals: a phone that hasn't accepted the portal will fail TLS or get redirected. The app should present this as "open a browser and log in to Wi-Fi" rather than as a generic offline state.

### Gaps
- I found no survey of how often Philippine (DepEd) school networks block UDP, use client isolation, or run captive portals. Behaviour at the client's school is unknown.
- I found no primary vendor doc about captive portals specifically breaking WebSockets.

## Q4. Mobile data in the Philippines: latency, jitter, loss, CGNAT, screen lock, Doze

### Takeaway
Philippine mobile data is usable but inconsistent. Only 45-55% of Opensignal tests per operator met its "consistent quality" thresholds in October 2025, and the country ranked 71st of 102 markets in Ookla's August 2026 mobile index. Mobile clients sit behind carrier-grade NAT, so only outbound client connections (such as WebSocket to a cloud server) work reliably. Android pauses the Godot app and Doze cuts network access when the screen is off, so a locked phone will drop its socket. Plan for reconnect on resume, not background keep-alive.

### Cited Findings
- Opensignal, October 2025: DITO won Best Network, with Consistent Quality 55% and Reliability Experience 55% (5G download 253.9 Mbps). Smart's Consistent Quality was 46.2% and it won 5G Games Experience. Globe's was 45.1%. — [unbox.ph, summarizing Opensignal Oct 2025](https://unbox.ph/news/dito-best-network-philippines-october-2025/); primary page (403 on fetch): [Opensignal Philippines Oct 2025](https://insights.opensignal.com/reports/2025/10/philippines/mobile-network-experience)
- Consistent Quality 55% means "over half of user tests met the minimum performance thresholds" (search snippet). — [Opensignal Philippines Oct 2025](https://insights.opensignal.com/reports/2025/10/philippines/mobile-network-experience)
- Opensignal April 2025: DITO won 14 of 16 national awards, with 5G download at 280.8 Mbps (search snippet). — [Opensignal Philippines Apr 2025](https://insights.opensignal.com/reports/2025/04/philippines/mobile-network-experience); [context.ph](https://context.ph/2025/07/08/dito-named-fastest-mobile-network-in-ph-by-opensignal/)
- The Philippines slipped to 75th in a global quarterly mobile network experience ranking (search snippet, Inquirer; date not confirmed). — [Inquirer Business](https://business.inquirer.net/?p=522137)
- Ookla Speedtest Global Index, August 2026: the Philippines ranked 71st of 102 markets for mobile, with a median mobile download of 66.33 Mbps against a global 109.05 Mbps (search snippet of a news aggregator, not Ookla itself). — [edgex news, Philippines climbs in Ookla rankings Aug 2026](https://pro.edgex.exchange/en-US/news/article/philippines-climbs-ookla-speed-rankings-august-2026)
- An old figure: Philippine mobile latency of 24 ms in November 2021 (search snippet; old, and from the Ookla index, which measures to the nearest test server). — [ABS-CBN / BusinessWorld coverage of Ookla](https://www.bworldonline.com/?p=420041)
- CGNAT: forum users report Globe puts customers behind CG-NAT with no public IPv4. Globe's mobile ASN AS132199 announces IPv6 networks. Both are low-authority sources (user forum and IP database). — [Plex forum thread](https://forums.plex.tv/t/port-forwarding-blowing-my-mind/549010?page=2); [db-ip AS132199](https://db-ip.com/as132199)
- Doze applies when the device is unplugged, stationary and has its screen off. It "suspends network access", ignores wake locks, and defers jobs and alarms, with less and less frequent maintenance windows. Foreground services are exempt, but "Don't start a foreground service just to prevent the system from determining that your app is idle." — [Android Developers, Doze and App Standby](https://developer.android.com/training/monitoring-device-state/doze-standby)
- Mobile OSes kill socket connections after the app has been in the background for a while, "as it's part of the lifecycle of mobile apps". The client must handle it (Heroic Labs/Nakama forum, search snippet). Godot exposes `NOTIFICATION_APPLICATION_PAUSED` and `NOTIFICATION_APPLICATION_RESUMED`. On Android and iOS the app can be killed while suspended. — [Heroic Labs forum](https://forum.heroiclabs.com/t/not-able-to-find-match-after-keeping-app-in-background/5074); [Godot docs, Handling quit requests](https://docs.godotengine.org/en/4.3/tutorials/inputs/handling_quit_requests.html)
- Supabase: "on mobile, the app can be suspended which can stop the heartbeat timers". For React Native it advises checking `isConnected()` and calling `connect()` when the app returns to the foreground. — [Supabase, Realtime heartbeat messages](https://supabase.com/docs/guides/troubleshooting/realtime-heartbeat-messages)

### Inferences
- Treat a screen lock as "student left". On `NOTIFICATION_APPLICATION_RESUMED`, force an immediate reconnect and rejoin rather than waiting for the 15 s stall timer, then ask for a full snapshot (see Q6). A foreground service to stay connected while locked is against Android guidance and not worth it for a classroom game.
- CGNAT plus phones on different carriers rules out phone-hosted servers and peer-to-peer without TURN. A cloud relay over wss:// avoids NAT entirely.
- A Consistent Quality score of 45-55% suggests that about half of mobile sessions will at times fall below the thresholds Opensignal uses for smooth apps. The weak/offline line states will be used on mobile data, not just in theory.

### Gaps
- I could not get 2025-2026 Philippine mobile latency, jitter or packet-loss figures. The Opensignal pages returned 403, Speedtest.net was blocked, and news coverage reports speeds and awards but not latency.
- I found no authoritative statement from Globe, Smart or DITO about CGNAT.
- Realme/ColorOS battery savers are often more aggressive than stock Doze. This was not researched.

## Q5. Wi-Fi with 30-40 phones on one AP: airtime contention, 2.4 GHz congestion, per-client limits, expected latency and jitter

### Takeaway
Vendor guidance designs around ~30 active devices per classroom AP. Enterprise APs are said to handle 40-50 users, and Kahoot suggests 10-15 Mbps up and 20-30 Mbps down per ~100 players, with enterprise APs for large events. This game's bandwidth is tiny, so the risk on a crowded or consumer AP is contention-driven jitter and loss, not throughput. I found no published latency or jitter measurements for a classroom.

### Cited Findings
- CommScope (2016, old): plan for "30 devices active per classroom at any time" in a ~35x35 ft room, with video demand of "2-5Mbps". It argues one AP per classroom may be unnecessary with modern APs. — [CommScope blog, K-12 Wi-Fi: one AP per classroom?](https://www.commscope.com/blog/2016/k-12-wi-fi-one-ap-per-classroom-is-it-necessary)
- "Most enterprise grade APs are capable of supporting 40-50 users without breaking a sweat" (vendor blog, search snippet, undated). — [TechGrid, one AP per classroom](https://techgrid.com/blog/4-data-backed-reasons-that-prove-one-ap-per-classroom-doesnt-make-any-sense)
- Zyxel smart-classroom guide: 30 concurrent clients at 4 Mbps each. With an 80 MHz channel, per-device airtime is 2.88% of channel capacity. It recommends two APs per classroom with load balancing (search snippet, undated). — [Zyxel, Best Practice for Smart Classroom](https://www.zyxel.com/library/assets/tech-library/deployment-guide/DeploymentGuide_BestPracticeforSmartClassroom.pdf)
- Kahoot: aim for about 10-15 Mbps upload and 20-30 Mbps download for ~100 participants, and use a dedicated Wi-Fi network with enterprise-grade APs for large events (search snippet). — [Kahoot Support, How to avoid connectivity issues](https://support.kahoot.com/hc/en-us/articles/115003198708-How-to-avoid-connectivity-issues)

### Inferences
- Bandwidth estimate for this game: 40 phones each sending ~60 B at 10 Hz is about 24 KB/s up in total. Each phone receives a batched snapshot of about 550 B at 10 Hz, about 5.5 KB/s per phone, or about 220 KB/s (~1.8 Mbps) total downlink. That is far below Kahoot's per-100-player guide. Throughput is not the constraint; airtime contention and retransmissions on a busy channel are.
- Many small frames from 40 clients cost more airtime than their byte count suggests, because each Wi-Fi frame has fixed overhead. Batching (one snapshot per tick rather than one message per player) and lower send rates on a weak line help more than compressing bytes.
- On 2.4 GHz with neighbouring classrooms' APs and phones on overlapping channels, expect occasional loss bursts and latency spikes of hundreds of ms. A ~1 s jitter buffer is a sensible margin. (Inference; I found no measurement to cite.)
- Consumer or home-grade APs often have a practical association limit near 30 clients (unverified). A single cheap router may refuse or drop some of 40 phones before bandwidth runs out. The teacher checklist should ask what AP the room uses.

### Gaps
- I found no published classroom measurements of Wi-Fi latency or jitter with 30-40 phones.
- No Cisco, Aruba or Ubiquiti primary doc was fetched for per-AP client limits or for 2.4 GHz vs 5 GHz in classrooms, and no figure for consumer AP client limits.
- The RMX1851 supports 5 GHz Wi-Fi to my knowledge, but this was not verified.

## Q6. Reconnect best practice: backoff with jitter, resuming state, idempotency, Phoenix/Supabase rejoin

### Takeaway
Use capped exponential backoff with full jitter, so 40 phones don't all reconnect at the same moment when the AP recovers. Phoenix already rejoins channels automatically, but messages in flight on the dead socket are lost. After every rejoin, send a full snapshot rather than trusting deltas, and keep answer submissions idempotent, which the app already does.

### Cited Findings
- Full jitter: `sleep = random(0, min(cap, base * 2 ** attempt))`. Without jitter, retries form "clusters of calls". With 100 contending clients, full jitter cut total calls by more than half compared with plain exponential backoff, and AWS calls jittered backoff "a standard approach for remote clients". (AWS Architecture Blog, March 2015, old but standard.) — [AWS, Exponential Backoff and Jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)
- Phoenix JS defaults: `reconnectAfterMs` is `[10, 50, 100, 150, 200, 250, 500, 1000, 2000][tries-1] || 5000` and `rejoinAfterMs` is `[1000, 2000, 5000][tries-1] || 10000`. `heartbeatIntervalMs` defaults to 30000. Pushes made while disconnected go to `sendBuffer` and are flushed on reconnect, but "any in-flight pushes on the old conn are lost, so channels need to rejoin". — [Phoenix socket.js source](https://raw.githubusercontent.com/phoenixframework/phoenix/main/assets/js/phoenix/socket.js)
- Supabase Realtime: the default heartbeat is 25 s. On heartbeat timeout "the client automatically attempts to reconnect" with backoff steps of 1 s, 2 s, 5 s and 10 s. Statuses are 'sent', 'ok', 'error', 'timeout' and 'disconnected'. — [Supabase, Realtime heartbeat messages](https://supabase.com/docs/guides/troubleshooting/realtime-heartbeat-messages)
- Supabase's troubleshooting index also covers silent disconnections in background apps, TooManyChannels errors and a "Concurrent Peak Connections" quota. The details were not on the index page. — [Supabase Realtime troubleshooting](https://supabase.com/docs/guides/realtime/troubleshooting)

### Inferences
- The Phoenix and Supabase defaults have no jitter: every client follows the same deterministic schedule. If NumXventure's GDScript client copies that schedule, 40 phones that lost the AP together will reconnect in lockstep. Add full jitter, with a cap of about 5-10 s.
- The app's 5 s heartbeat and 15 s stall rule are already more aggressive than Supabase's 25 s default, which is good for detecting dead Wi-Fi. Check the Supabase connection quota before 40 phones plus the teacher plus reconnect churn go live.
- After a rejoin, the hub should send (or the client should request) a full snapshot of all player positions and game state. Don't assume missed broadcasts arrive, because Phoenix drops in-flight pushes on a dead socket.
- Queued position pushes are worthless after a reconnect. Drop them and send only the current position, so the Phoenix `sendBuffer` doesn't replay stale moves.

### Gaps
- Not fetched: the Supabase doc on "Handling Silent Disconnections in Background Applications" and the exact concurrent-connection quota for the project's plan.

## Q7. How classroom live apps (Kahoot, Wayground/Quizizz, Gimkit, Blooket, Minecraft Education) handle bad school networks

### Takeaway
All the browser-based quiz apps run on WebSockets over TCP 443. They publish domain allow-lists and network check pages, and Kahoot and Gimkit ask schools to exempt them from SSL inspection. Minecraft Education is the outlier: it needs UDP/TCP 19132-19133 for multiplayer, and is the one most often blocked.

### Cited Findings
- Kahoot: ports 80 and 443 on create.kahoot.it, play.kahoot.it, kahoot.it and test.kahoot.it. WebSocket URLs `wss://play.kahoot.it/cometd` and `wss://kahoot.it/cometd` must be allow-listed. Firewalls may close long-open connections, and SSL inspection breaks certificates. About 10-15 Mbps up and 20-30 Mbps down per ~100 participants (search snippet). — [Kahoot Support](https://support.kahoot.com/hc/en-us/articles/115003198708-How-to-avoid-connectivity-issues); older brief: [Kahoot! for schools solution brief, Oct 2019](https://kahoot.com/files/2019/10/kahoot-for-schools-solution-brief-oct-2019.pdf)
- Wayground (formerly Quizizz): allow-list wayground.com, quizizz.com, joinmyquiz.com, quizizz.app.link, `*.wayground.com` and `*.quizizz.com`. "WebSockets for socket.wayground.com on port 443" are required. Network check at quizizz.com/check. — [Wayground, Network Access Guide](https://wayground.com/home/domain-safelisting)
- Gimkit: `*.gimkitconnect.com`, ports 80/443, WebSockets allowed, SSL inspection bypass, check at gimkit.com/check (third-party source). — [coopboardgames.com](https://coopboardgames.com/online-gaming/troubleshooting-in-gimkit-game-servers/)
- Blooket: `*.blooket.com` on 80/443 and `wss://*.blooket.com` on 443 via Cloudflare (third-party source). — [axeetech](https://axeetech.com/blooket-websocket-error/)
- Minecraft Education multiplayer: port 19132 TCP and UDP (range 19132-19133). The host should have at least 1.5 Mbps. Multiplayer works within the same Microsoft 365 tenant. Allow `https://meeservices.azurewebsites.net`. These are search snippets from a pre-production support mirror and a teacher blog, possibly outdated. — [Minecraft Education support (PPE mirror)](https://edusupportppe.minecraft.net/hc/en-us/articles/4418649871636); [cdsmythe.com](https://cdsmythe.com/?p=1429)

### Inferences
- The industry pattern for live classroom games on unknown school networks is cloud relay over WSS on 443, a domain allow-list for IT, an SSL-inspection exemption, and a self-check URL. NumXventure's Supabase design already matches it.
- None of the quiz apps publish per-device bandwidth beyond Kahoot's per-100 figure. Their traffic, like NumXventure's, is small.

### Gaps
- The official Gimkit and Blooket pages were not reached, and the official Minecraft Education network page was not fetched directly.
- I found no public statement from any of these apps about reconnect strategy or update rates.

## Q8. Recommendation material: safe default transport for 40 phones on unknown Wi-Fi, and when UDP is worth it

### Takeaway
Keep WebSocket over 443 (Supabase Realtime) as the only transport. It is what Kahoot, Wayground, Gimkit and Blooket use. It gets through school firewalls and mobile CGNAT. Its head-of-line stalls (about 0.25-0.6 s per loss, occasionally more than 1 s) fit inside the existing ~1 s playback buffer for non-competitive movement. UDP (ENet or WebRTC) only pays off for fast, competitive, sub-200 ms gameplay on a controlled network. It would need either a UDP-reachable server (blocked by isolation and CGNAT) or WebRTC plus signalling plus TURN, which would mostly fall back to TCP/443 on strict networks anyway.

### Cited Findings
- Media products prefer UDP but keep TCP/443 as the fallback, at reduced quality. — [Google Meet network prep](https://knowledge.workspace.google.com/admin/meet/prepare-your-network-for-meet-meetings-and-live-streams)
- Discord voice shows the cost of UDP-only: it fails on school and work networks that block UDP. — [Discord Support](https://support.discord.com/hc/en-us/articles/115001310031)
- Quiz apps standardise on WSS/443 with allow-lists. — [Wayground](https://wayground.com/home/domain-safelisting); [Kahoot](https://support.kahoot.com/hc/en-us/articles/115003198708-How-to-avoid-connectivity-issues)
- In Godot, UDP transports beyond raw ENet/UDP need a plugin (webrtc-native) and a signalling server. — [Godot WebRTC docs](https://docs.godotengine.org/en/stable/tutorials/networking/webrtc.html)
- TCP head-of-line blocking costs at least 1-2 RTT or an RTO per loss, and the RTO doubles on repeated loss. — [Gaffer On Games](https://gafferongames.com/post/udp_vs_tcp/); [RFC 6298](https://www.rfc-editor.org/rfc/rfc6298)

### Inferences
Mitigations to keep on WSS, roughly by value:
1. Only the newest data matters. Send absolute positions, never deltas. After a stall, snap to the newest sample per player instead of replaying the backlog.
2. Batch per tick on the hub: one snapshot message for all players rather than 40 small ones. This cuts Wi-Fi frames and airtime.
3. Use full-jitter backoff with a cap of about 5-10 s on reconnect, on top of Phoenix's deterministic schedule.
4. Send a full snapshot after every join or rejoin, and drop queued stale position pushes.
5. Reconnect immediately on `NOTIFICATION_APPLICATION_RESUMED`. Treat a locked screen as away.
6. Give IT a one-page checklist: allow `*.supabase.co` on 443 with WebSockets, exempt it from SSL inspection, turn off client isolation only if a LAN mode is ever revived, and prefer 5 GHz with an AP rated for 40+ clients. Add an in-app network check like gimkit.com/check.
7. Keep answers and scores idempotent and reliable over WSS or HTTP with retries, as the app already does. Answers must never ride on a lossy channel.

UDP becomes worth it only if all of these hold: gameplay needs sub-200 ms reaction, the network is known and controlled (the school confirms UDP is allowed and there is no isolation), and there is budget for WebRTC signalling and TURN.

### Gaps
- No field data from the client's school exists yet. A one-class pilot logging RTT, stall counts and reconnects per phone over WSS would show whether any of this matters in practice.
