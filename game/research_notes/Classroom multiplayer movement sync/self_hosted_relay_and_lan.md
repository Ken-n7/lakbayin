# Self-hosted relay servers and the teacher's device as a LAN host (NumXventure, Oct 2026)

Scope: (a) a small dedicated relay (headless Godot 4 export, or a tiny Node/Go/Python WebSocket relay) on cheap or free hosting; (b) the teacher's laptop or phone as host on a local network; (c) hybrids (laptop host reached through a tunnel). Supabase stays for accounts, questions, scoring, gems and session state. Research date 2026-10-08. School is assumed to be in the Philippines (Waray-speaking, so likely Eastern Visayas, not Manila).

Project baselines (from the brief, not re-measured): Supabase hub today = ~165 msg/s at 30 students, 98% delivered, 3 snapshots/s, ~1.0-1.2 s playback delay. LAN spike = Godot WebSocket host on the Ryzen 7 5700U laptop, 10 snapshots/s, 40 simulated phones, 100% delivered, under 14% of one CPU core.

---

## Q1. Headless Godot 4 dedicated server: how to run it, resource use, and can it serve ~40 clients at 5-20 Hz?

### Takeaway
Godot 4 needs no special server binary: any export template run with `--headless` (plus the "Export as dedicated server" resource mode with Strip Visuals) is a dedicated server. An idle headless Godot 4.6 process measured here used ~72 MB RAM and 0.6-2.2% of one core, and this project's own spike already showed 40 WebSocket clients at 10 Hz under 14% of a laptop core. 40 clients is well inside what Godot's WebSocket/ENet peers handle. The public failure reports start around 80-100 clients with full high-level RPC sync, not with a hand-rolled snapshot relay.

### Cited Findings
- Since Godot 4.0 any Godot binary can run as a server with `--headless`; "You do not need to use a specialized server binary anymore, unlike Godot 3.x." `--headless` enables the headless display server and the Dummy audio driver. — [Godot docs: Exporting for dedicated servers](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html)
- Two ways to ship it: a dedicated export preset for the server platform, or a PCK only, paired with a matching export template binary. — [Godot docs: dedicated servers](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html)
- The "Export as dedicated server" resource mode adds the `dedicated_server` feature tag and enables resource stripping. "Strip Visuals" replaces textures and materials with placeholder classes, and the docs recommend it "whenever possible, unless the server needs to access image data". Detect server mode with `OS.has_feature("dedicated_server")`, `DisplayServer.get_name() == "headless"`, or `OS.get_cmdline_user_args()`. The docs suggest systemd or Docker on Linux for restarts and logging. — [Godot docs: dedicated servers](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html)
- Transports: ENet (default), WebRTC, WebSocket. The HTML5/web platform "offers WebSockets and WebRTC support but lacks ... raw access to low-level protocols like TCP and UDP", so ENet/UDP does not work in a browser build. Android exports need the `INTERNET` permission. — [Godot docs: High-level multiplayer](https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html)
- `ENetMultiplayerPeer.create_server(port, max_clients = 32, max_channels = 0, in_bandwidth = 0, out_bandwidth = 0)`: the default cap is 32 clients ("any number up to 4095 may be used"), so 40 phones need an explicit `max_clients`. — [Godot docs: ENetMultiplayerPeer](https://docs.godotengine.org/en/stable/classes/class_enetmultiplayerpeer.html)
- `WebSocketMultiplayerPeer.create_server(port, bind_address = "*", tls_server_options = null)`. Defaults: inbound and outbound buffer 65535 bytes, max queued packets 4096, handshake_timeout 3.0 s. wss:// on the Godot side needs `TLSOptions.server()` with a certificate and key. — [Godot docs: WebSocketMultiplayerPeer](https://docs.godotengine.org/en/stable/classes/class_websocketmultiplayerpeer.html)
- A raw relay is `TCPServer` plus `WebSocketPeer.accept_stream()`, one WebSocketPeer per client. The docs warn that WebSocket "still uses a TCP connection, which is good for reliability but not for latency" and is not ideal for "fast-paced games". WebSocket works in both native and web exports. — [Godot docs: WebSocket](https://docs.godotengine.org/en/stable/tutorials/networking/websocket.html)
- Community load test (posted 2026-03-02): a Godot 4.4.1 (.NET) MMO demo using the High Level Multiplayer API over ENet, on a 2-core / 2 GB Linux VM, hit "server CPU spikes followed by mass disconnects of all connected players" at around 80-100 concurrent bot clients. Switching to the Telepathy TCP library "improved significantly". No replication filtering or bandwidth optimisation was used. — [Godot Forum: MMO tech demo with Godot 4.4.1](https://forum.godotengine.org/t/our-experience-building-an-mmo-tech-demo-with-godot-4-4-1-net-c/134348)
- Older Godot 3 data point (itch.io devlog, date shown only as "3 years ago", so roughly 2023, unverified): a WebSocket game ran 60 clients across 6 headless server processes (10 each) on a small VM at "60-80% of CPU". Headless rendering cut RAM to about a third, and a non-headless 120-client test thrashed at ~300 MB per process. — [SuperSpace devlog](https://bobgar.itch.io/superspace/devlog/610789/balance-polish-and-stress-testing-the-server)
- An empty Godot 4.6 beta1 project (Windows, Mono, non-headless) used ~200 MB RAM with D3D12 and ~400 MB with Vulkan. A forum reply suggests the Dummy audio driver and Dummy physics servers to save memory. No headless figure was given. — [Godot Forum: default memory usage](https://forum.godotengine.org/t/default-memory-usage-concerns-200mb-400mb-for-empty-project/129801)
- **Local measurement (this session, no URL):** Godot 4.6.3.stable editor binary, `godot --headless`, minimal project with a `TCPServer` listening and no clients, on a Ryzen 3 7320U Linux laptop: RSS ~72-74 MB. CPU was ~0.6% of one core with `Engine.max_fps = 30` and ~2.2% with no FPS cap. An export template (release) binary would likely be smaller, but that was not measured.
- A forum thread about headless memory (2025-03-11) contains no numbers, only "test with `--headless`". — [Godot Forum: memory usage of a headless instance](https://forum.godotengine.org/t/how-is-the-memory-usage-of-a-headless-godot-instance/104954)

### Inferences
- A headless Godot relay fits in 256 MB RAM (~72 MB measured idle plus snapshot state for 40 players). 512 MB leaves headroom for GC and buffers if the relay is C#. The binary and PCK would be the same codebase as the game, so the snapshot format and quantisation code are shared. That is the main advantage over Node/Go.
- CPU: the project's own spike (<14% of one Ryzen 7 5700U core at 40 clients, 10 Hz) is the best available benchmark. It sits above two very small allocations: Fly's 6.25% shared-CPU baseline (Q2) and Render/Koyeb free tiers' 0.1 vCPU. Plan on a burstable or full vCPU, or drop to 5 Hz.
- Use a hand-rolled snapshot broadcast (one packed byte array per tick, sent via `WebSocketPeer.put_packet` or a single `MultiplayerPeer` packet), not `MultiplayerSynchronizer`/RPC per player. The 80-100-client failure above used the high-level API.
- Set `Engine.max_fps` (or run the tick from a Timer) so the headless loop does not spin. The local test showed ~3-4x lower idle CPU with a cap.
- A Node/Go/Python relay would use a similar or smaller footprint (no cited benchmark found here). It adds a second language and a second implementation of the snapshot codec.

### Gaps
- No published, dated benchmark of headless Godot 4 RAM or CPU per WebSocket client. The ~72 MB figure is one local measurement of the editor binary, not of a stripped export template.
- No public measurement of Godot 4 WebSocket servers at 40 clients x 5-20 Hz on a 0.1-vCPU or 1/16-core shared instance. It would need a load test on the actual target instance (the project's `tools/sim` walkers could drive it).
- No Godot doc states a recommended client count for WebSocketMultiplayerPeer.

---

## Q2. Hosting: free tiers and cheapest tiers in 2026 (limits, egress, Southeast Asia regions, WebSocket/TLS/UDP)

### Takeaway
No host gives a free, always-on, Singapore-region server for this use in late 2026. Fly.io dropped its free allowance. Render's free tier sleeps after 15 minutes, has 0.1 CPU, and since 1 Aug 2026 includes only ~5 GB of bandwidth. Oracle halved its Always Free Arm allowance in June 2026 and reclaims idle instances. Google's free VM is US-only with 1 GB egress. Koyeb's free instance is Frankfurt/Washington-only and its Starter tier closed to new sign-ups. The realistic cheap options with a Singapore region are Fly.io (~$2-4/month), Railway Hobby ($5/month including $5 usage), and DigitalOcean ($4-6/month). Hetzner Singapore became expensive after its June 2026 price rise.

### Cited Findings

**Latency from the Philippines (relevant to region choice)**
- WonderNetwork average pings from Manila: Hong Kong 18.4 ms, Singapore 28.9 ms, Mumbai 103.7 ms, Tokyo 158.1 ms, San Jose 167.8 ms, Los Angeles 169.7 ms, Portland 191.5 ms, Frankfurt 234.7 ms, Sydney 237.4 ms, Seattle 239.8 ms, Washington 248.8 ms. — [WonderNetwork pings from Manila](https://wondernetwork.com/pings/Manila)
- Estimated Philippines-to-Singapore pings by area: Manila/Luzon 40-60 ms, Cebu 45-65 ms, Davao/Mindanao 50-70 ms. These are vendor estimates, ISP-dependent, and unverified. — [space-node.net (2026)](https://space-node.net/blog/minecraft-server-hosting-philippines-2026)

**Fly.io**
- "New organizations don't have a free tier or a monthly free usage allowance." New accounts get a free trial of "up to 2 hours of Machine runtime or 7 days, whichever comes first." — [Fly.io pricing docs](https://docs.fly.io/about/pricing)
- shared-cpu-1x costs $2.19/month with 256 MB, $3.69/month with 512 MB, and $6.70/month with 1 GB. Egress is $0.02/GB for North America and Europe, $0.04/GB for Asia Pacific, Oceania and South America (Singapore), and $0.12/GB for Africa and India. Inbound is free. Shared IPv4 and IPv6 are free; a dedicated IPv4 is $2/month. — [Fly.io pricing docs](https://docs.fly.io/about/pricing)
- Regions in Asia-Pacific: `sin` (Singapore), `nrt` (Tokyo), `syd` (Sydney). Hong Kong and Mumbai are not listed. — [Fly.io regions](https://docs.fly.io/reference/regions)
- Shared vCPUs get a quota of "5ms for each shared vCPU" per 80 ms, which is 6.25% of a core. Unused time accrues as a burst balance: 5 s initially, up to 500 s maximum. When the balance runs out, the vCPU "is limited to running at its baseline quota". — [Fly.io CPU performance](https://docs.fly.io/machines/cpu-performance)
- UDP to public clients works but needs a dedicated IPv4 and binding to `fly-global-services`. TCP works on the shared IPv4. — [Fly.io UDP and TCP](https://docs.fly.io/networking/udp-and-tcp)
- WebSockets work with no special configuration. Fly terminates TLS at the edge, so the app sees plain traffic on one internal port (wss:// comes free). The example config showed a soft limit of 20 and a hard limit of 25 connections before scaling. That is an older blog post, and a community answer cites a default of 1000, so the two disagree. — [Fly.io blog: WebSockets and Fly](https://fly.io/blog/websockets-and-fly/); [Fly community thread](https://community.fly.io/t/websockets/25827)

**Render**
- Free web services spin down after "15 minutes without receiving any inbound traffic. This includes both HTTP requests and WebSocket messages". Spin-up takes about one minute. The free allowance is 750 instance hours per workspace per month, on a single instance. "Render might restart a Free web service at any time." — [Render docs: Free instances](https://render.com/docs/free)
- WebSockets are supported with no fixed timeout, but connections "close automatically when the instance is replaced (for example, during a deploy)". Render recommends ping/pong keepalive and client reconnect with exponential backoff. — [Render docs: WebSockets](https://render.com/docs/websocket)
- Regions: Oregon, Ohio, Virginia, Frankfurt, Singapore. — [Render docs: Regions](https://render.com/docs/regions)
- New workspace plans: Hobby is free, Pro is $25/month flat, and bandwidth overage is "$0.15 for each additional GB". Legacy workspaces auto-migrated on 2026-08-01, and the new plans "include less bandwidth than their legacy counterparts". — [Render changelog (2026-04-23)](https://render.com/changelog/updated-plans-for-render-workspaces)
- Secondary source, checked against render.com/pricing on 2026-08-06: Hobby bandwidth went from 100 GB to 5 GB included, and Pro from 500 GB to 25 GB. The free instance is 512 MB RAM with 0.1 CPU. — [jwatte.com Render review (updated 2026-08-06)](https://jwatte.com/blog/render-com-platform-review.md)

**Railway**
- Free trial: $5 of credit for 30 days, no card. Free plan: $0/month with $1 of monthly usage credit. Hobby: $5/month including $5 of usage. Prices: CPU $0.00000772 per vCPU-second (~$20 per vCPU-month), memory $0.00000386 per GB-second (~$10 per GB-month), egress $0.05/GB. — [Railway pricing](https://railway.com/pricing)
- Regions include "Southeast Asia Metal", Singapore (`asia-southeast1-eqsg3a`). The page does not say whether every plan can use every region. — [Railway deployment regions](https://docs.railway.com/reference/deployment-regions)

**Oracle Cloud Always Free**
- Current official text: "the first 1,500 OCPU hours and 9,000 GB hours per month" of A1 Arm, which is "equivalent to 2 OCPUs and 12 GB of memory". Also up to two VM.Standard.E2.1.Micro AMD VMs and 10 TB/month of outbound data. Always Free instances must be in the home region. — [Oracle docs: Always Free resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
- Idle reclamation: an instance counts as idle if, over 7 days, 95th-percentile CPU is below 20%, network utilisation is below 20%, and memory is below 20% (memory applies to A1 only). — [Oracle docs: Always Free resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
- The A1 allowance was cut from 4 OCPU / 24 GB to 2 OCPU / 12 GB effective 2026-06-15, "without public announcement". Instances over the new limit "are shut down until the user manually resizes them". — [InfoQ (2026-07-03)](https://infoq.com/news/2026/07/oracle-cloud-free-tier-limits/)
- Users report reclaimed instances and terminated accounts, with support replying "your account has been terminated, and we are unable to provide additional information or reactivate it". These are anecdotal forum reports. — [LowEndTalk](https://lowendtalk.com/discussion/comment/4277227/); [ServerCompass (2026-06-20)](https://servercompass.app/blog/oracle-cloud-free-tier-changes-migrate-to-low-cost-vps)

**Google Cloud**
- Free tier: 1 non-preemptible e2-micro VM per month, only in `us-west1` (Oregon), `us-central1` (Iowa) or `us-east1` (South Carolina). Also 30 GB-months of standard disk and "1 GB of outbound data transfer from North America to all region destinations (excluding China and Australia) per month". — [Google Cloud free features](https://docs.cloud.google.com/free/docs/free-cloud-features)

**AWS**
- Accounts created on or after 2025-07-15: up to $200 in credits ($100 at sign-up plus $100 earned). The Free plan ends 6 months after sign-up or when credits run out, whichever comes first, replacing the old 12-month tier. Accounts created earlier keep the legacy free tier. — [AWS What's New (2025-07)](https://aws.amazon.com/about-aws/whats-new/2025/07/aws-free-tier-credits-month-free-plan/); [Neowin](https://www.neowin.net/news/aws-free-tier-overhauled-new-users-get-200-in-credits-but-theres-a-catch/)

**Hetzner**
- Price change effective 2026-06-15 for new orders and rescales (existing servers keep their price unless rescaled). Germany/Finland: CX23 €3.99 → €5.49/month and CAX11 €4.49 → €5.99. USA: CPX11 €5.99 → €17.49. Singapore: CPX12 €7.99 → €15.49 ($17.99) and CPX22 €15.99 → €26.49. All prices exclude IPv4. — [Hetzner docs: price adjustment](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)
- Hetzner's cloud page marked the CX and CAX (cost-optimised) lines "Currently not available" from about 2026-06-26, still as of 2026-08-17. — [Findstack (2026-09-16)](https://findstack.com/resources/hetzner-price-increase-2026)
- Singapore plans include 0.5-5 TB/month of traffic, with extra traffic at $8.49/TB. — [Hetzner Cloud Singapore](https://www.hetzner.com/cloud-singapore/). EU plans include 20 TB, against roughly 1 TB in the US and 0.5 TB in Singapore (secondary sources). — [Northflank](https://northflank.com/blog/hetzner-cloud-server-price-increases); [egresscost.com](https://egresscost.com/hetzner)

**DigitalOcean**
- $4/month: 1 vCPU, 512 MiB, 10 GB SSD, 500 GiB transfer. $6/month: 1 vCPU, 1 GiB, 25 GB, 1,000 GiB transfer. Per-second billing from 2026-01-01. Datacenters include Singapore and Bangalore. — [DigitalOcean droplet pricing](https://www.digitalocean.com/pricing/droplets)
- Transfer is pooled per team, overage is $0.01/GiB, inbound is free, and there is "no regional variations on bandwidth pricing" for Droplets. — [DigitalOcean bandwidth billing](https://docs.digitalocean.com/platform/billing/bandwidth/)

**Vultr** (official pricing page returned 403, so these are secondary sources only)
- $2.50/month is IPv6-only (~$3.50 with IPv4), and 1 vCPU / 1 GB / 25 GB / 1 TB costs ~$5-6/month. — [onedollarvps (2026)](https://onedollarvps.com/pricing/vultr-pricing); [learnwithhasan](https://learnwithhasan.com/self-hosting-hub/vps-providers/vultr/)
- Vultr reportedly has a Manila datacenter (opened 2023), but one source says the Manila 1 vCPU / 1 GB plan costs $24/month. Unverified, and could not be checked on vultr.com. — [itsourcecode (2026)](https://itsourcecode.com/web-hosting/best-cheap-vps-providers-under-10-dollars-2026/)

**Koyeb**
- Free Instance: 0.1 vCPU, 512 MB, 2 GB SSD, one per organisation, only in Frankfurt or Washington D.C. It scales to zero after 1 hour with no traffic. The cheapest paid instance, `eco-nano`, is 0.1 vCPU / 256 MB at ~$1.61/month. — [Koyeb docs: instances](https://www.koyeb.com/docs/reference/instances)
- Mistral AI agreed to buy Koyeb (2026-02-17), and "new users will no longer be able to sign up for its Starter tier". This contradicts the instance docs above, which still list the free instance. — [TechCrunch (2026-02-17)](https://techcrunch.com/2026/02/17/mistral-ai-buys-koyeb-in-first-acquisition-to-back-its-cloud-ambitions)

### Inferences
- Region: Singapore (~29 ms from Manila, likely ~45-70 ms from the Visayas) is the obvious choice. Every US or EU free option (GCP, Koyeb free, Render US) adds 170-250 ms round trip. That is tolerable with the current 1.0-1.2 s playback buffer but wasteful.
- Cheapest viable always-on option: Fly.io `sin` shared-cpu-1x 256 MB at $2.19 plus ~$0.40-2.50 of APAC egress (Q3), about $3-5/month. Machines can also be auto-stopped between classes. Watch the 6.25% CPU baseline. The 500 s burst balance at ~14% load drains at ~0.0775 CPU-s per second, so roughly 1.8 h of continuous play before throttling, then ~2.2 h idle to refill. Three back-to-back sessions could hit throttling. Test it, or use a bigger shared size (price not fetched).
- Railway Hobby ($5/month, Singapore): a 0.1-vCPU / 0.1 GB relay running 24/7 costs about $2 of CPU and $1 of RAM per month by the listed rates, plus egress at $0.05/GB. That likely fits inside the $5 credit.
- Render free does not fit. It sleeps (a ~1 min cold start when class begins), 0.1 CPU is below the measured 14% load at 10 Hz, and 5 GB of included bandwidth is exceeded within a week (Q3), then $0.15/GB.
- Oracle Always Free (Singapore home region possible, 10 TB egress) costs nothing but carries two risks. A relay idle most of the week meets the "idle" definition (P95 CPU < 20%), and accounts can be terminated without explanation. It is not suitable as the only server for a client deployment.
- A DigitalOcean $4 droplet in SGP1 (500 GiB included) is the simplest classic VPS. It needs solo-dev maintenance (Q6).
- TLS: Fly and Render terminate TLS at their edge, so Godot clients get wss:// with no certificate work. A raw VPS needs its own certificate (Godot `TLSOptions.server()` or a reverse proxy).
- UDP/ENet would need a VPS or Fly with a dedicated IPv4 ($2/month). Render, Railway and Koyeb (as documented here) are HTTP/WebSocket-oriented. WebSocket over TLS is the transport every host supports and the one the project already uses.

### Gaps
- Oracle Singapore region availability and Always Free capacity there were not checked.
- Railway: whether the Singapore region is available on the Free and Hobby plans is not stated.
- Fly.io: the current default connection concurrency limit (25 vs 1000) needs confirming in current `fly.toml` docs. Price of shared-cpu-2x / performance-1x not fetched.
- Render's 5 GB Hobby bandwidth comes from a secondary source. The official changelog only says "less bandwidth".
- Vultr official prices and the Manila datacenter could not be verified (vultr.com returned 403).
- Koyeb's free-instance status for new sign-ups in Oct 2026 is contradictory.

---

## Q3. Bandwidth: 40 phones, 5-20 Hz snapshots of 40 positions — per session and per month

### Takeaway
A packed snapshot of 40 players is ~240-330 bytes on the wire per phone, after TLS, WebSocket and TCP/IP overhead. At 10 Hz that is ~95-130 KB/s (~1 Mbit/s) of server egress, or ~0.34-0.47 GB per hour of play. At 3 one-hour sessions per day that is ~23-31 GB/month over 22 school days, or ~31-42 GB over 30 days. That costs about $1-2/month on Fly APAC or Railway and is trivial against DigitalOcean, Hetzner or Oracle allowances. It overflows Render's 5 GB and GCP's 1 GB. Per-message overhead is a large share of each packet, so the server must send one combined snapshot per tick, not 40 per-player forwards (that would be ~10x more).

### Cited Findings
- WebSocket framing: a server-to-client frame has a 2-byte header plus 2 extended-length bytes for payloads of 126-65535 bytes, and server frames are not masked. — [RFC 6455 §5.2](https://www.rfc-editor.org/rfc/rfc6455#section-5.2)
- TLS 1.3 record overhead: a 5-byte record header, a 1-byte inner content type, and a 16-byte AEAD tag for AES-GCM or ChaCha20-Poly1305. — [RFC 8446 §5.2](https://www.rfc-editor.org/rfc/rfc8446#section-5.2)
- Minimum IPv4 + TCP headers are 20 + 20 bytes. — [RFC 791](https://www.rfc-editor.org/rfc/rfc791); [RFC 9293](https://www.rfc-editor.org/rfc/rfc9293)
- Egress prices used below: Fly APAC $0.04/GB ([Fly pricing](https://docs.fly.io/about/pricing)); Railway $0.05/GB ([Railway pricing](https://railway.com/pricing)); Render overage $0.15/GB ([Render changelog](https://render.com/changelog/updated-plans-for-render-workspaces)); DigitalOcean 500-1,000 GiB included, then $0.01/GiB ([DO bandwidth](https://docs.digitalocean.com/platform/billing/bandwidth/)); Hetzner Singapore 0.5+ TB included, then $8.49/TB ([Hetzner SG](https://www.hetzner.com/cloud-singapore/)); Oracle 10 TB/month ([Oracle docs](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)); GCP free 1 GB/month ([GCP free](https://docs.cloud.google.com/free/docs/free-cloud-features)). Inbound is free on Fly and DigitalOcean (same sources).

### Calculation (computed for this note)
Assumptions: 40 phones receive every snapshot. Each player is 4 B (x, y as u16) or 6 B (plus id and facing/animation byte), with an 8-16 B snapshot header. Wire overhead is ~70 B per message (IPv4 20 + TCP 20 + TLS 1.3 22 + WS 4). TCP ACKs, retransmits and TLS handshakes are ignored. A session is 60 minutes of play. A month is 3 sessions/day x 22 school days (66 sessions) or x 30 days (90).

| Per player | Bytes/snapshot | Hz | Egress | 1 h session | 66 sessions/mo | 90 sessions/mo |
|---|---|---|---|---|---|---|
| 4 B | 238 | 3 | 28.6 KB/s | 103 MB | 6.8 GB | 9.3 GB |
| 4 B | 238 | 5 | 47.6 KB/s (0.38 Mbit/s) | 171 MB | 11.3 GB | 15.4 GB |
| 4 B | 238 | 10 | 95.2 KB/s (0.76 Mbit/s) | 343 MB | 22.6 GB | 30.8 GB |
| 4 B | 238 | 20 | 190 KB/s (1.5 Mbit/s) | 685 MB | 45.2 GB | 61.7 GB |
| 6 B | 326 | 3 | 39.1 KB/s | 141 MB | 9.3 GB | 12.7 GB |
| 6 B | 326 | 5 | 65.2 KB/s (0.52 Mbit/s) | 235 MB | 15.5 GB | 21.1 GB |
| 6 B | 326 | 10 | 130 KB/s (1.04 Mbit/s) | 469 MB | 31.0 GB | 42.2 GB |
| 6 B | 326 | 20 | 261 KB/s (2.1 Mbit/s) | 939 MB | 62.0 GB | 84.5 GB |

Naive relay (each player's update forwarded individually to the 39 others, ~84 B per message): 5 Hz is 655 KB/s, 2.4 GB/h, ~156 GB/month at 66 sessions. 10 Hz is 1.3 MB/s, 4.7 GB/h, ~311 GB/month.

### Inferences
- Monthly cost at the 10 Hz / 6 B case (31-42 GB): Fly APAC ≈ $1.25-1.70; Railway ≈ $1.55-2.10; Render ≈ $3.90-5.60 of overage on top of the 5 GB; DigitalOcean, Hetzner SG and Oracle $0 extra (inside their allowances). GCP free (1 GB) is exceeded on day one.
- Upstream (each phone sending its path every 0.5 s) is inbound to the server, which is free on Fly and DigitalOcean. It does not affect egress cost.
- Classroom downlink: ~1 Mbit/s total is negligible for the school uplink, and each phone receives only ~3 KB/s at 10 Hz. Wi-Fi airtime (many small frames to 40 clients) matters more than bytes. See Q4.
- Even 20 Hz stays under 100 GB/month, so bandwidth is not the deciding factor between hosts. CPU allocation, region and sleep behaviour are.

### Gaps
- Session length and school days per month are assumptions. Rescale linearly (GB per month = KB/s x 3600 x hours x sessions / 1e6).
- Some hosts bill on different byte counts (e.g. including Ethernet framing). Real traffic also adds TCP ACK and retransmit bytes on lossy Wi-Fi, which were not modelled.

---

## Q4. Teacher's device as a LAN host: hotspot limits, routers, client isolation, firewall, discovery, captive portals

### Takeaway
Phone hotspots are capped at about 10 clients on mainstream Android (Pixel is officially 10, Samsung typically 10), so a phone cannot host 30-40 students. Cheap TP-Link routers list hard caps of 15-64 clients, with vendor staff recommending about 15-30 for good performance. Travel routers claim more (GL.iNet Beryl AX "70+"). On school Wi-Fi the risk is client isolation, which blocks phone-to-laptop traffic outright and is common on guest/BYOD SSIDs. The laptop also needs a Windows Firewall inbound allow, which applies per network profile. LAN works technically (the project's spike proved it) but depends on network gear the client says it does not control.

### Cited Findings
- Pixel: "You can share your phone's mobile data with up to 10 other devices via a Wi-Fi hotspot." Some carriers limit tethering. — [Google Pixel Help](https://support.google.com/pixelphone/answer/2812516?hl=en)
- AOSP: the hotspot client maximum is the minimum of the hardware limit (`config_wifiHardwareSoftapMaxClientCount`) and the carrier limit (`CarrierConfigManager.Wifi#KEY_HOTSPOT_MAX_CLIENT_COUNT`), and is exposed to apps as `SoftApCapabilities#getMaxSupportedClients`. — [Android source: Wi-Fi hotspot (Soft AP)](https://source.android.com/docs/core/connect/wifi-softap)
- Samsung: "typically allow up to 10 devices", varying by model and carrier. The cap is user-adjustable under Mobile Hotspot > Configure > Advanced > Maximum connections. This is from aggregator/community sources, not a current Samsung spec page. — [Samsung Members community](https://r2.community.samsung.com/t5/Galaxy-M/How-to-increase-decrease-limit-on-no-of-devices-connected-on/td-p/22626670); [nerdytechblog](https://nerdytechblog.com/how-to-set-up-hotspot-on-samsung/). An older official Samsung page (Galaxy S6 era) also gives 10. — [InformIT (Galaxy S6)](https://informit.com/articles/article.aspx?p=2457061)
- TP-Link community answers per model: Archer C60 up to 64 devices but "no more than 15" recommended; TL-WA941HP max 32; TL-WR841HP max 31 (15 recommended); TL-WR940N V1 max 15, V2 max 32; RE200 extender max 16. "For most SOHO class routers, the recommended value for wireless clients is 20-30." — [TP-Link community: Archer C60](https://community-test.tp-link.com/en/home/forum/topic/167428); [TP-Link community: TL-WR941HP](https://community-test.tp-link.com/en/home/forum/topic/181262); [TP-Link community: client limit 15](https://community-test.tp-link.com/en/home/forum/topic/3251); [TP-Link community: limited to 16](https://community-test.tp-link.com/en/home/forum/topic/177556)
- GL.iNet Beryl AX (GL-MT3000) travel router: "can connect with 70+ devices simultaneously" (vendor marketing). — [GL.iNet travel router guide](https://www.gl-inet.com/blogs/blog/your-guide-to-choosing-the-perfect-glinet-travel-router)
- Client isolation "prevents wireless clients from communicating with one another". In Meraki bridge mode it blocks all traffic except to the default gateway, including wired devices on the same VLAN. "Basic Client Isolation is enabled by default when the SSID is configured for NAT mode and cannot be disabled." It is used on guest and BYOD SSIDs. — [Cisco Meraki: Wireless Client Isolation](https://documentation.meraki.com/MR/Design_and_Configure/Firewall_and_Traffic_Shaping/Wireless_Client_Isolation)
- Isolation is set per AP/BSSID and breaks AirPlay, AirPrint "and any other services where devices are expected to talk to each other". — [OpenWrt forum](https://forum.openwrt.org/t/can-anyone-explain-how-isolate-clients-works/244879)
- Windows shows a "Windows Security Alert" when an app first acts as a server, with checkboxes for Private and Public networks. Guidance is to allow only Private, and Public profiles are for places like cafés. — [InformatiWeb](https://us.informatiweb.net/tutorials/it/windows/configure-the-firewall-of-your-computer--4.html); [NinjaOne](https://www.ninjaone.com/blog/allow-apps-through-your-windows-firewall/); [Microsoft Support: Firewall and network protection](https://support.microsoft.com/en-us/help/4028544/windows-update-faq)
- Android Wi-Fi filters out packets "not explicitly addressed to the device". A `WifiManager.MulticastLock` (permission `CHANGE_WIFI_MULTICAST_STATE`) is needed to receive multicast, and it "can cause a noticeable battery drain". — [Android MulticastLock reference](https://developer.android.com/reference/kotlin/android/net/wifi/WifiManager.MulticastLock)
- Godot `PacketPeerUDP`: "Some Android devices might require the `CHANGE_WIFI_MULTICAST_STATE` permission and this option to be enabled to receive broadcast packets too" (`set_broadcast_enabled`). The same note applies to `join_multicast_group`. — [Godot docs: PacketPeerUDP](https://docs.godotengine.org/en/stable/classes/class_packetpeerudp.html)

### Inferences
- The teacher's phone as hotspot host is ruled out at 30-40 students (10-client cap on mainstream Android), which matches the client's finding.
- Laptop as Windows Mobile Hotspot: not researched here, but Windows' built-in Mobile Hotspot is widely reported to cap at 8 devices (unverified, see Gaps). It would not cover the class either.
- A dedicated router for 40 phones means a mid-range or "70+ client" class device, not the cheapest TP-Link N router (15-32 caps). Even within the cap, 40 phones receiving 10 small frames/s each is airtime-bound. The vendor's "15 recommended" figure suggests buying above the minimum. Cost is ~$50-100 and the teacher has to carry and set it up (price not researched).
- School Wi-Fi: if the SSID uses client isolation (common on student/BYOD networks, and enforced in NAT mode on Meraki), phones cannot reach the laptop at all. The game should detect this ("can't reach host") and fall back to the online path rather than hang.
- Windows Firewall: the prompt appears on first `listen()`. If the school network is classified as Public and the teacher only ticked Private, phones are silently blocked. Shipping an installer that adds an inbound rule for the port, or telling the teacher to tick both, avoids this.
- Discovery: UDP broadcast discovery on Android needs `CHANGE_WIFI_MULTICAST_STATE` (Godot exposes no MulticastLock API, so it would need a plugin or Android export tweak; unverified). Simpler: the teacher's screen shows a QR code or short IP:port, or the laptop publishes its LAN IP to the Supabase session row and phones read it from there. That works across isolation-free subnets with no broadcast.
- Captive portals: phones that have not cleared the portal may get no internet. That breaks Supabase login and scoring even if LAN traffic flows. LAN mode still needs internet for Supabase unless offline answer queueing exists (the project has "hold actions on a bad line").

### Gaps
- No primary source found for Windows 10/11 Mobile Hotspot's client cap (commonly cited as 8).
- Exact Samsung One UI hotspot limit range (e.g. 1-10 vs higher) for current Galaxy A-series phones common in the Philippines: the Samsung Members page returned 403.
- No source found on how many Philippine public schools (DepEd) enable client isolation, or on DepEd Wi-Fi configuration.
- Captive portal behaviour for LAN-only traffic was not researched (it varies by vendor: some allow local subnet before login, some do not).
- No measured data on Wi-Fi airtime limits for 40 clients at 10 Hz on consumer routers.

---

## Q5. Hybrid: the teacher's laptop as relay, reached over the internet through a tunnel

### Takeaway
It is technically possible, but no free tunnel suits a client deployment. Cloudflare Tunnel (free, carries WebSockets) is the most robust, but it needs a domain on Cloudflare and `cloudflared` running on the teacher's laptop. trycloudflare quick tunnels are for testing only with no uptime guarantee. ngrok free has 1 GB/month (one or two sessions' worth) and an interstitial page. Tailscale Funnel has unspecified bandwidth limits. playit.gg is game-oriented with Singapore PoPs, but free routing is "not always optimal". Every option keeps the laptop as a single point of failure (sleep, Wi-Fi drop, the "paused window stalls the hub" problem already seen) and adds a hop. It beats Supabase only on message-rate limits, not on reliability.

### Cited Findings
- Cloudflare Tunnel uses outbound-only connections from `cloudflared` to Cloudflare. — [Cloudflare docs: Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/)
- Public hostnames proxy HTTP/HTTPS directly. "Non-HTTP services require installing `cloudflared` on the client" (TCP, SSH, RDP, SMB). UDP is not listed. DNS records are created in the Cloudflare dashboard, which implies a domain on the account. — [Cloudflare docs: Tunnel routing](https://developers.cloudflare.com/tunnel/routing/index.md)
- "WebSockets are supported on all Cloudflare plans." Cloudflare closes idle WebSockets and "may restart servers, which terminates WebSockets connections". It recommends keepalives. — [Cloudflare docs: WebSockets](https://developers.cloudflare.com/network/websockets/)
- Tunnel is free on all plans, including Free (secondary source, May 2026). — [flaviocopes guide](https://flaviocopes.com/cloudflare-tunnel/)
- Quick Tunnels (trycloudflare.com): "up to 200 in-flight requests", no SSE, "for testing and development", "no uptime guarantee". — [Cloudflare docs: Quick Tunnels](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/)
- ngrok Free: 1 GB/month data transfer, 20k HTTP/S requests/month, up to 3 endpoints, an interstitial page on HTTP/S endpoints, TCP only with credit-card verification, 5k TCP/TLS connections/month. Hobbyist is $10/month with 5 GB, no interstitial, and is aimed at "game servers". — [ngrok pricing](https://ngrok.com/pricing)
- Tailscale Funnel: available on all plans, listens only on ports 443, 8443 and 10000, "only works over TLS-encrypted connections", and is "subject to non-configurable bandwidth limits". Traffic goes through Funnel relay servers. — [Tailscale docs: Funnel](https://tailscale.com/kb/1223/funnel)
- playit.gg lets you "host game servers from your own computer ... No port forwarding required". It has 19 datacenters, including Singapore, Japan, Australia and India in Asia. Premium is $3/month ($30/year). — [playit.gg](https://playit.gg/); [Playit Premium](https://playit.gg/support/playit-premium/)
- playit.gg free tier: up to 3 tunnels on "Global Anycast", "no set bandwidth limits" (they may contact very heavy users), and 4 ports (16 with Premium). Free routing "is not always optimal ... a user in North America [could] get routed through Singapore". Premium adds Regional Tunnels. These come from third-party summaries quoting playit docs. — [pinggy.io (2025)](https://pinggy.io/blog/best_playit_gg_alternatives_in_2025); [playit.gg forum: traffic limits](https://discuss.playit.gg/t/traffic-limits/5574)

### Inferences
- Path length: phone → school uplink → tunnel PoP (Singapore at best) → back to the same school's uplink → laptop, then the reverse. Every snapshot crosses the school's upstream twice. Latency is likely ~2x the Singapore RTT, and the laptop's internet connection becomes the bottleneck and single point of failure.
- Per-session egress (~0.35-0.47 GB at 10 Hz, Q3) exhausts ngrok Free's 1 GB in 2-3 sessions. ngrok's free interstitial page also breaks non-browser WebSocket clients unless a skip header is sent (behaviour assumed, not verified).
- "Allowed?": Cloudflare's terms restrict serving video and large files on Free/Pro/Business ([Tunnel routing](https://developers.cloudflare.com/tunnel/routing/index.md)). Small WebSocket game traffic is not in that category, and nothing found forbids it. Quick tunnels are explicitly not for production.
- A small Singapore VPS or Fly machine ($2-6/month) removes the laptop from the path and costs about the same as playit Premium or ngrok Hobbyist. The tunnel hybrid only wins if the budget is exactly zero and the teacher's laptop is reliably online.

### Gaps
- No measured latency or jitter for Cloudflare Tunnel, Tailscale Funnel or playit.gg from the Philippines.
- Whether ngrok's interstitial affects Godot WebSocket clients was not verified.
- Tailscale Funnel's actual bandwidth cap is not published.

---

## Q6. What a solo developer must maintain for a VPS relay

### Takeaway
On a PaaS (Fly, Railway, Render) the platform handles TLS, restarts and deploys. The developer owns the relay code, auth checks and reconnect logic. On a raw VPS (DigitalOcean, Hetzner, Oracle) the developer also owns OS patching, the TLS certificate and its renewal, a process supervisor (systemd or Docker), monitoring and abuse limits. In all cases the relay should accept only signed-in students by verifying the Supabase access token on connect, which Supabase supports offline via its JWKS endpoint.

### Cited Findings
- Godot recommends systemd services (automatic restarts, logging) or Docker for Linux server deployment. — [Godot docs: dedicated servers](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html)
- Supabase publishes `GET https://<project-id>.supabase.co/auth/v1/.well-known/jwks.json` with the public keys of asymmetric JWT signing keys. It returns no keys if the project still uses the legacy shared secret. The docs show `jose`'s `createRemoteJWKSet` and `jwtVerify`. JWKS is edge-cached for 10 minutes, and the docs say not to cache it much longer ("might make revocation difficult"). Claims to check include `sub`, `exp` and `role`. — [Supabase docs: JWTs](https://supabase.com/docs/guides/auth/jwts)
- The legacy HS256 shared secret is discouraged: "A shared secret that is in the hands of a malicious actor can be used to impersonate your users." — [Supabase docs: JWTs](https://supabase.com/docs/guides/auth/jwts)
- Asymmetric signing keys allow "local JWT verification without calling Supabase servers". — [Supabase: JWT Signing Keys](https://supabase.com/features/jwt-signing-keys)
- PaaS behaviour the code must tolerate: Render drops WebSockets on every deploy or instance replacement (SIGTERM with a 30 s grace period, extendable to 300 s) and recommends ping/pong and client reconnect with exponential backoff. — [Render docs: WebSockets](https://render.com/docs/websocket). Cloudflare restarts also drop WebSockets. — [Cloudflare docs: WebSockets](https://developers.cloudflare.com/network/websockets/). Fly terminates TLS at the edge, so the app needs no certificate. — [Fly.io blog: WebSockets](https://fly.io/blog/websockets-and-fly/)
- Godot's own WebSocket server can do wss:// directly with `TLSOptions.server(key, cert)`. — [Godot docs: WebSocketMultiplayerPeer](https://docs.godotengine.org/en/stable/classes/class_websocketmultiplayerpeer.html)
- Oracle free instances can be reclaimed when idle, and accounts terminated without explanation, so a Free-tier VPS adds re-provisioning as a maintenance task. — [Oracle docs](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm); [InfoQ](https://infoq.com/news/2026/07/oracle-cloud-free-tier-limits/)

### Inferences
- Minimal secure handshake: the phone opens wss:// and sends `{access_token, session_id}` as its first message (or in the URL query). The relay verifies the token's signature against the cached JWKS and checks `exp`, `role == authenticated` and `aud`. It then checks the student belongs to the session (one Supabase RPC per connect, or a session-membership claim), joins them to that session's room, and drops the socket otherwise. GDScript has no JOSE library. A Godot relay would need hand-written ES256/RS256 verification with the `Crypto` class (RSA verify exists; ECDSA support is unverified), or one REST call per connect to `auth/v1/user`. This is a real argument for a tiny Node/Go relay, which has mature JOSE libraries.
- Abuse protection at classroom scale: per-socket message-rate and size caps (drop over N msgs/s or over 1 KB), a max-connections-per-session cap (~45), an idle kick, and session IDs generated by Supabase rather than guessable. No public, unauthenticated endpoint besides the WebSocket upgrade.
- Raw VPS checklist: unattended security upgrades; firewall allowing only 22 and 443; a reverse proxy with automatic HTTPS (e.g. Caddy) or a certbot renewal timer; a systemd unit with `Restart=always`; an external uptime ping; and log rotation. Estimated at a few hours of setup and ~1 h/month of care. This is an estimate, not sourced.
- On Fly or Railway that list shrinks to the relay, a health check and the deploy command. Given the price difference (~$0-3/month), a PaaS in Singapore is the low-maintenance choice for a solo developer.
- Fallback design: keep the existing Supabase teacher-hub path as automatic fallback when the relay is unreachable. The relay only carries positions, so its outage degrades movement smoothness, not scoring or gems.

### Gaps
- No source fetched on Let's Encrypt certificate lifetimes, renewal cadence or upcoming short-lived-certificate changes.
- Whether Godot 4.6's `Crypto` class can verify ES256 (ECDSA P-256) JWT signatures was not verified. Supabase's default asymmetric key type was not checked.
- No cited data on attack or abuse rates against small game WebSocket endpoints.
