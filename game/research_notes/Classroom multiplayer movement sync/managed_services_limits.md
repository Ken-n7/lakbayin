# Managed realtime / multiplayer backends: free and cheap tier limits for a 40-phone classroom game

Research date: 2026-10-08. All prices USD. "Fetched" means the official page was loaded on that date; "search snippet" means the page itself was blocked (Photon docs sit behind a cookie/JS wall) and the figure comes from the search engine's extract of that URL.

Common assumptions used in every cost estimate below (stated once, reused):
- 40 phones + 1 teacher laptop = 41 concurrent connections.
- 3 sessions/day x 22 school days = 66 sessions/month, 30-60 min each = **33-66 session-hours/month**.
- Design (a), current teacher hub: 165-215 messages/s through the service, counted per recipient (165 measured at 30 students; 215 is the brief's upper bound for 40). Snapshot 2.6 KB at 30 students (about 3.5 KB if it scales linearly to 40).
- Design (b), server-authoritative: a server sends one snapshot per player per tick at 5-10 Hz = 200-400 outbound msg/s, plus phone uploads at the current 2/s = 80 inbound msg/s, giving **280-480 msg/s**. If phones also send at tick rate the total rises to 400-800 msg/s.

---

## 1. Supabase Realtime: exact Free / Pro limits, message counting, price, spend cap, what happens over the per-second limit, 2025-2026 changes

### Takeaway
Free allows only 100 messages/s and 2 M messages/month, so the current hub (165-215 msg/s) is already over Free's per-second limit. The measured cut-off near ~520 msg/s matches Pro's 500 msg/s. Pro is $25/month with 5 M messages included, then $2.50 per million. Pro **with the spend cap turned off** raises the per-second limit to 2,500 msg/s and connections to 10,000. With the cap on (the Pro default), Realtime usage is cut off for the rest of the billing cycle once the 5 M quota is used up.

### Cited Findings
- Per-plan limits table (Free / Pro / Pro no spend cap / Team / Enterprise):
  - Concurrent connections: 200 / 500 / 10,000 / 10,000 / 10,000+
  - Messages per second: 100 / 500 / 2,500 / 2,500 / 2,500+
  - Channel joins per second: 100 / 500 / 2,500 / 2,500 / 2,500+
  - Channels per connection: 100 on every plan
  - Presence keys per object: 10. Presence messages/s: 20 / 50 / 1,000 / 1,000 / 1,000+. Presence calls per client: 5 per 30 s
  - Broadcast payload size: 256 KB (Free) / 3,000 KB (Pro and up). Postgres Changes payload: 1,024 KB
  - Broadcast replay: 72 h retention, 25 messages per replay request, on all plans
  — [Supabase Realtime Limits](https://supabase.com/docs/guides/realtime/limits)
- How the per-second limit counts: "An `event` is a WebSocket message delivered to, or sent from a client", so both inbound and outbound count. — [Supabase Realtime Limits (md)](https://supabase.com/docs/guides/realtime/limits.md)
- What happens over the per-second limit: "Connections will be disconnected if your project is generating too many messages per second. `supabase-js` will reconnect automatically when the message throughput decreases below your plan limit." The WebSocket error is `tenant_events`. Other errors: `too_many_channels`, `too_many_connections`, `too_many_joins`. Limits are "configurable per project"; contact support for more. — [Supabase Realtime Limits](https://supabase.com/docs/guides/realtime/limits.md)
- Projects that "consistently exceed" plan limits "by a significant margin" may be manually suspended, logging `RealtimeDisabledForTenant`. Restoring access requires contacting support. — [Realtime: Project suspended for exceeding quotas](https://supabase.com/docs/guides/troubleshooting/realtime-project-suspended-for-exceeding-quotas.md)
- Billing count: "Each broadcast message counts as one message sent plus one message per subscribed client that receives it" (a broadcast to N subscribers = N+1). "Each database change counts as one message per client that listens to the event." Worked example: 8.5 M messages on Pro gives 3.5 M x $2.50 = $10 (as quoted on the page). — [Manage Realtime Messages usage](https://supabase.com/docs/guides/platform/manage-your-usage/realtime-messages)
- Monthly quotas: Free 2 M messages / 200 peak connections. Pro and Team 5 M messages / 500 peak connections. Overage $2.50 per 1 M messages and $10 per 1,000 peak connections. Billed in whole packages (rounded up). — [Realtime pricing](https://supabase.com/docs/guides/realtime/pricing); [Manage Realtime Messages usage](https://supabase.com/docs/guides/platform/manage-your-usage/realtime-messages)
- Plan prices: Free $0. Pro "from $25/month". Team "from $599/month". Pro and Team include $10/month compute credits. Free projects pause "after 1 week of inactivity", limit of 2 active projects. Spend caps are "on by default on the Pro Plan". Max message size: 256 KB on Free, 3 MB on Pro. — [Supabase Pricing](https://supabase.com/pricing)
- Spend cap: "available only with the Pro Plan". Once a quota is exceeded with the cap on, "further usage of that item is disallowed until the next billing cycle". Realtime Messages and Realtime Peak Connections are both covered. — [Supabase Cost Control](https://supabase.com/docs/guides/platform/cost-control). The usage page words it more softly ("notifications and a grace period rather than automatic charges") — [Manage Realtime Messages usage](https://supabase.com/docs/guides/platform/manage-your-usage/realtime-messages). These two pages conflict on how hard the stop is.
- "Broadcast from Database" was released in April 2025. It lets Postgres triggers send Broadcast messages to clients, as a more scalable path than Postgres Changes. — [Supabase blog: Realtime Broadcast from Database](https://supabase.com/blog/realtime-broadcast-from-database.md)

### Inferences
- The project's measurements ("clean at ~260-350 msg/s, cut off past ~520 msg/s", "Too many messages per second") match the **Pro** limit of 500 msg/s, not Free's 100. Either the project is on Pro, or Free is enforced loosely. The coordinator should confirm the plan. On Free, the current 165 msg/s already breaks the documented limit.
- Turning the spend cap off on Pro is the cheapest single change that raises the per-second ceiling from 500 to 2,500 msg/s. It doesn't rescue the original all-to-all design, which needed about 30 x 7 x (1+30) = about 6,500 msg/s with fan-out counted.
- With the spend cap on, the 5 M Pro quota lasts about 8.4 hours of play at 165 msg/s, roughly 3 school days of three 1-hour sessions. After that, Realtime is disallowed for the rest of the billing cycle. With the cap off, it bills about $62-$143/month for design (a) (section 6).
- Broadcast replay (72 h, 25 msgs/request) is useful for late joiners or reconnects recovering recent discrete events, such as "answer accepted" or a gem awarded. It's no help for movement, since 25 messages is about 8 s of 3 Hz snapshots and stale positions aren't wanted anyway. Broadcast from Database suits pushing scoring results out of the Postgres RPC, not position traffic. Each delivery is still billed per listener.
- The 2.6 KB snapshot is far under the 256 KB Free and 3 MB Pro payload caps. Payload size isn't a constraint.

### Gaps
- I couldn't find a dated changelog entry showing when the "Pro (no spend cap)" column (2,500 msg/s) or the replay rows were added, so I can't confirm which limits changed during 2025-2026. The limits page has no "last updated" date.
- The docs name the error `tenant_events`. They don't print the exact human-readable string "Too many messages per second" that the project saw, so that string can't be matched to docs.
- Neither page says whether the Free plan gets hard-blocked or only suspended manually after exceeding the 2 M monthly quota.

---

## 2. Photon (Exit Games): free 20 CCU, 100 CCU plan, next tier, per-room message limits, Godot 4 support

### Takeaway
The free plan is capped at 20 CCU "for development only", so 41 connections can't run on it. The cheapest fit is the **100 CCU one-time plan at $95 for 12 months** (0.3 TB traffic/month). The next tier is 500 CCU at $95/month. The 500 msg/s per room limit is soft (fair use). The only Godot 4 path from Photon itself is the **Fusion Godot SDK 3.0.0, a GDExtension development preview** for Godot 4.6+ that is "not intended for production".

### Cited Findings
- Free: 20 CCU, "For Development Only", "Limited to 60.0 GB Traffic per Month", no burst. 100 CCU one-time: $95 for 12 months, "Includes 0.3 TB Traffic per Month", no burst. 500 CCU: $95/month, 1.5 TB/month, burst included. 1,000 CCU: $185/month, 3.0 TB. 2,000 CCU: $370/month, 6.0 TB. Premium Cloud: $0.29/CCU, 3.0 GB traffic per peak CCU per month. Traffic overage: $0.05/GB (Europe, Canada, USA, Russia) and $0.10/GB (Asia, Australia, China, India, Japan, Africa, South America, Turkey, UAE). The page describes these as Realtime plans and doesn't break out Fusion, Quantum or PUN separately. — [Photon pricing](https://www.photonengine.com/pricing) (fetched)
- Per-room message limit (search snippets; the docs pages are behind a cookie wall): "keep your messages per second per room count below 500". It is not enforced but "relies on a fair use policy". It is a soft limit you may exceed "if your game does not affect other games and if you are willing to pay for the extra traffic". For traffic only the average across all rooms matters; for client load the per-room maximum matters. No message limit on self-hosted Photon Server. — [Photon Realtime FAQ](https://doc.photonengine.com/en-US/realtime/current/reference/faq); [Photon forum](https://forum.photonengine.com/discussion/comment/52984/)
- Counting (search snippets): "Any operation request or operation response or event is considered a message". An RPC to one player is 2 messages (1 up + 1 down), and a multicast is 1 + 1 per target. Msg/s per room for N players each sending F msg/s to everyone is about R = N^2 x F. — [Photon forum: How messages per second per room are calculated](https://forum.photonengine.com/discussion/comment/36673/); [Photon forum: How does the Msg/s count scale](https://forum.photonengine.com/discussion/10765/how-does-the-msg-s-count-scale-with-multiple-players)
- Godot (search snippets): "Fusion Godot SDK 3.0.0 is a development preview and is not intended for production use". It requires a Fusion 3 AppId and Godot 4.6+, and supports Windows, Linux, macOS, iOS, Android and web. It ships as a GDExtension dropped into `addons/fusion/` with no custom engine build. Preview builds are dated 2026-03-31 (Build 311), 2026-05-07 (Build 424) and 2026-07-01 (Build 517). It offers shared-authority mode, with the Photon server caching state for late joiners. — [Fusion Godot SDK & Download](https://doc.photonengine.com/fusion-godot/current/getting-started/sdk-download); [Fusion Godot intro](https://doc.photonengine.com/fusion-godot/current/fusion-3-intro); [Godot Asset Store: photon fusion](https://store.godotengine.org/asset/photon/photon-fusion/)
- Community options: "Photon Realtime GDExtension" (C++, Godot 4.3+ branch) on the Godot Asset Store, and an older "Photon GDScript Client SDK for Godot3.X". — [Godot Asset Store: photon realtime gdextension](https://store.godotengine.org/asset/adsk-dev/photon-realtime-gdextension/); [Godot Asset Library: Photon GDScript Client SDK for Godot3.X](https://godotengine.org/asset-library/asset/edit/5179)

### Inferences
- 41 connections exceed the free 20 CCU, and "no burst" suggests the 21st client is refused. The 100 CCU plan (~$7.90/month amortized) is the minimum.
- Traffic: both free and paid plans work out to 3 GB per CCU per month (60 GB / 20, 300 GB / 100).
- The project is likely in Asia (Philippines time zone), so overage would be $0.10/GB on an Asia region.
- Design (a) on Photon: phones send bundles to the teacher only (80 up + 80 down) and the teacher multicasts 3/s to 40 (3 + 120), about 280 msg/s per room. That is under the 500 soft limit. The original all-to-all design (40 x 40 x 2 Hz, about 3,200 msg/s) would have been far over it.
- Design (b) needs a server. Photon Realtime/Fusion shared mode has no custom server logic, so the "server" would be the teacher client (master client) and fan-out is counted the same. 40 x 5-10 Hz down + 80 up = 280-480 msg/s, inside the soft limit at 5 Hz and close to it at 10 Hz.
- Relying on a preview GDExtension for a school deployment is a real risk.

### Gaps
- I couldn't load Photon's docs (JS/cookie wall), so the per-room limit, counting rules and Godot SDK details come from search snippets, not full pages.
- I couldn't confirm whether Fusion 3 uses the same CCU plans and prices as Realtime, or whether Fusion 3 has its own free tier.
- I couldn't verify maintenance of the community Photon Realtime GDExtension.

---

## 3. Nakama / Heroic Labs: Heroic Cloud pricing, self-hosting, Godot 4 client, match handlers, message rates

### Takeaway
The Nakama server is free to self-host and actively released (v3.41.0, 2026-09-18). It needs CockroachDB or Postgres and at least a small VM. **Heroic Cloud prices aren't published** (dynamic or "contact us") and charge for allocated resources even when idle. The official Godot 4 client is maintained in commits but hasn't had a tagged release since v3.4.0 (March 2024). Authoritative matches run Lua/Go/TS handlers at 1-60 ticks/s.

### Cited Findings
- Heroic Cloud prices Nakama by CPU (Nakama 1-64+ cores, database 1-16+ cores). It advertises "No DAU/MAU/CCU limits" and a "Development tier: Burstable CPU, Micro Database, Continuous Integration". The page shows a template placeholder ("${{cost}}") instead of a figure. Satori costs from $600/month. Support plans run $2,000 (Studio Basic) and $6,000 (Studio Standard). — [Heroic Cloud pricing](https://heroiclabs.com/pricing/)
- Billing is usage-based, "calculated daily and invoiced monthly through Stripe". "A deployment costs the same whether or not players are connected to it, because charges track allocated resources rather than traffic." Costs depend on "environment type (development or production) and scaling tier". No public numbers or free trial found. — [Heroic Cloud billing support](https://heroiclabs.com/docs/heroic-cloud/concepts/organizations/billing-support/)
- A forum mention of roughly $400 for a development-tier instance surfaced only via search summary and is **unverified**. — [toolradar Nakama pricing (aggregator)](https://toolradar.com/tools/nakama/pricing)
- Self-hosting: Nakama needs CockroachDB or another Postgres wire-compatible DB (CockroachDB, Aurora PG, or vanilla Postgres). It can run on GCP "g1-small", with "n1-standard-1" recommended for production. Don't run Nakama and the DB on the same shared hardware in production. Docker Compose is the quickest setup. — [Nakama Docker install](https://heroiclabs.com/docs/nakama/getting-started/install/docker/); [Heroic forum: minimum system requirements](https://forum.heroiclabs.com/t/minimum-system-requirements-for-cloud-server-and-or-cockroach-memory-leak/6423)
- Server activity: heroiclabs/nakama latest release v3.41.0 (2026-09-18), previous v3.40.0 (2026-07-13), last commit 2026-09-22, 13.5k stars. — [GitHub heroiclabs/nakama](https://github.com/heroiclabs/nakama) (via GitHub API)
- Godot client: nakama-godot supports "Godot Engine 4.0+" on master, with a `godot-3` branch for Godot 3. It provides realtime sockets and integrates with Godot's high-level multiplayer API, and is installable from the Asset Library. — [GitHub heroiclabs/nakama-godot](https://github.com/heroiclabs/nakama-godot). Latest tagged release v3.4.0 (2024-03-19), but last commit 2026-09-21, 26 open issues, 778 stars, not archived (via GitHub API, 2026-10-08).
- Authoritative match handlers in Lua, Go and TypeScript. The tick rate is "the desired number of match_loop() calls per second and must be between 1 and 60, inclusive". — [Nakama Lua match handler](https://heroiclabs.com/docs/nakama/server-framework/lua-runtime/function-reference/match-handler/); [Nakama TS match handler](https://heroiclabs.com/docs/nakama/server-framework/typescript-runtime/function-reference/match-handler)

### Inferences
- For a solo student, Nakama would mean a second backend next to Supabase, plus its own DB (it can't simply reuse Supabase Postgres without care). It also means a VM that isn't cited here.
- A 5-10 Hz authoritative match with 40 players is well inside the 1-60 tick range, and Nakama has no per-message billing when self-hosted.
- The gap between commits (2026) and the last release (2024) means users should pin a commit rather than rely on the Asset Library build.

### Gaps
- No published Heroic Cloud price or free trial was found for 2026.
- No official minimum RAM figure for Nakama itself was found, only VM class names.
- No documented per-match message-rate cap was found beyond the tick-rate range.

---

## 4. Colyseus: Cloud pricing, self-hosting, Godot client, delta state sync

### Takeaway
Colyseus Cloud starts at **$15/month with no free tier**, "No CCU/DAU/MAU limits" and "Unlimited bandwidth". The server is open source and very active (0.18.x, Oct 2026). The **official Godot SDK is a beta GDExtension** (colyseus/native-sdk, v0.18.8 on 2026-10-02) that supports Android and schema delta-state callbacks.

### Cited Findings
- "Get started from $15/mo". Free tier: "Not at this moment". No auto-scaling (manual upgrades). "No imposed CCU/DAU/MAU limits". 32 regions. — [Colyseus Cloud managed hosting](https://colyseus.io/cloud-managed-hosting/)
- Pricing page: Colyseus Cloud from $15/mo with "Managed SSL Certificates, No CCU/DAU/MAU limits, Unlimited bandwidth, Support by email". — [Colyseus pricing](https://colyseus.io/pricing)
- The compute plan classes are "Low Performance" (previous-generation Intel, regular SSD, for development), "High Frequency (Recommended)" (3 GHz+ Xeon, NVMe), "High Performance" and "Dedicated (Enterprise)". The page I fetched lists no per-plan vCPU, RAM or price. — [Colyseus Cloud compute plans](https://docs.colyseus.io/cloud/compute-plans). The compute plan is charged upfront monthly. — [Colyseus Cloud pricing & billing](https://docs.colyseus.io/cloud/pricing-billing) (search snippet)
- Godot SDK: official, built on the shared "Colyseus Native SDK", delivered as a GDExtension. "The GDExtension is in **beta**, and may not be stable" and "expect some breaking changes". Supports Windows, macOS, Linux, iOS, Android and Web. State sync uses schema callbacks with optional codegen. Godot Mono uses the NuGet package instead. — [Colyseus docs: Godot](https://docs.colyseus.io/getting-started/godot)
- colyseus/native-sdk: latest release v0.18.8 (2026-10-02), 25 stars. colyseus/colyseus server: release @colyseus/tools@0.18.9 (2026-10-05), 7.3k stars (via GitHub API). — [GitHub colyseus/native-sdk](https://github.com/colyseus/native-sdk); [GitHub colyseus/colyseus](https://github.com/colyseus/colyseus)
- A community GDScript client ("Godot Colyseus") also exists on the Asset Library. — [Godot Asset Library: Godot Colyseus](https://godotengine.org/asset-library/asset/edit/16922)

### Inferences
- With unlimited bandwidth and no CCU caps, design (b) on Colyseus Cloud should cost a flat ~$15/month. Whether the $15 plan handles 40 clients at 10 Hz is unverified but plausible for such a small room.
- Schema delta patches send only changed fields, which suits (b) better than full JSON snapshots.
- Self-hosting means a Node.js process on any VPS, but I didn't gather a cited VPS price.
- The small native-sdk (25 stars, beta) is the weak link for Godot. The fallback is raw `WebSocketPeer` plus Colyseus's binary protocol, which is much more work.

### Gaps
- No per-plan vCPU/RAM/price table could be extracted (the pricing simulator is interactive).
- No free trial is documented.
- I didn't check the maintenance status of the community GDScript client.

---

## 5. Other candidates: Cloudflare Durable Objects / PartyKit, Ably, Pusher, Firebase RTDB, Hathora, Edgegap, Rivet, W4 Cloud

### Takeaway
Cloudflare Durable Objects is the standout cheap option. Its free plan includes 100,000 requests/day, incoming WebSocket messages are billed at 20:1, and **outgoing messages are free**. A 40-phone room likely fits the free plan, but it needs a small JS/TS server, and Godot connects with its built-in `WebSocketPeer`. Ably and Pusher bill per delivered message like Supabase and have small free tiers. Firebase RTDB bills download GB. Hathora **shut down on 2026-05-05**. Edgegap and Rivet have usable free tiers, but both mean running your own server code.

### Cited Findings
**Cloudflare Durable Objects / PartyKit**
- Workers Free: 100,000 requests/day and 13,000 GB-s/day duration, SQLite-backed objects only (5 GB total storage). Workers Paid: 1 M requests/month + $0.15/M, and 400,000 GB-s/month + $12.50/M GB-s. — [Cloudflare DO pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)
- "A 20:1 ratio is applied to incoming WebSocket messages." "There is no charge for outgoing WebSocket messages, nor for incoming WebSocket protocol pings." "Durable Objects that are idle and eligible for hibernation are not billed for duration". Calling `accept()` without the Hibernation API bills duration for the whole connection. "Duration billing charges for the 128 MB of memory your Durable Object is allocated, regardless of actual usage." Example 4 (100 DOs x 100 hibernatable sockets, 1 msg/min) comes to about $20.65/month. Examples mention a "minimum $5/mo usage" on Paid. — [Cloudflare DO pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)
- SQLite storage billing was scheduled to begin no earlier than 2026-01-07. — [Cloudflare DO pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)
- Cloudflare acquired PartyKit (announced 2024-04-05). PartyKit runs on Durable Objects and existing users can deploy it to their own Cloudflare account for free. — [Cloudflare blog: Cloudflare acquires PartyKit](https://blog.cloudflare.com/cloudflare-acquires-partykit). The library is now `partyserver` in cloudflare/partykit, latest partyserver@0.5.10 (2026-08-03) (via GitHub API). — [GitHub cloudflare/partykit](https://github.com/cloudflare/partykit)
- Godot 4 includes a built-in `WebSocketPeer` client class, the "raw WebSocket" route for DO, PartyKit, Pusher and similar services. — [Godot docs: WebSocketPeer](https://docs.godotengine.org/en/stable/classes/class_websocketpeer.html)

**Ably**
- Free: 6 M messages/month, 200 concurrent connections, 200 concurrent channels, 500 msg/s per account, 64 KiB max message. Standard: $29/month + $2.50 per million messages, $1.00 per million connection-minutes, $1.00 per million channel-minutes. — [Ably pricing](https://ably.com/pricing)
- Limits (Free / Standard): account message rate 500 / 2,500 per s. **Per-connection inbound 50/s, per-connection outbound 50/s, per-channel publish 50/s** on both plans. Connections and channels 200 / 10,000. Over-rate publishes "can be rejected locally… and have an error code returned". Other limits are soft, with email warnings. — [Ably limits](https://ably.com/docs/platform/pricing/limits)
- Counting: 1 inbound per publish plus 1 outbound per subscriber, so 1 publish to 10 subscribers = 11 messages, or 12 with echo (on by default). Volume discounts go down to $0.50/M. — [Ably message counting](https://ably.com/docs/platform/pricing/message-counting)

**Pusher Channels**
- Plans (price / messages per day / connections): Sandbox free / 200k / 100. Startup $49 / 1 M / 500. Pro $99 / 4 M / 2,000. Business $299 / 10 M / 5,000 (higher tiers up to $1,199). "If you publish one message to 50 subscribers, that's 51 messages." Over-limit handling is only described as email warnings and "plenty of headroom". — [Pusher Channels pricing](https://pusher.com/channels/pricing/)

**Firebase Realtime Database**
- Spark (free): 100 simultaneous connections, 1 GB stored, 10 GB/month downloaded, one database per project. Blaze: 200k connections per database, $5/GB stored after 1 GB, 360 MB/day (~10 GB/month) download free then $1/GB. — [Firebase pricing](https://firebase.google.com/pricing)
- Godot: the community GDScript addon GodotFirebase is at v6.0.6 (2026-05-27), last push 2026-09-13, 686 stars (via GitHub API). — [GitHub GodotNuts/GodotFirebase](https://github.com/GodotNuts/GodotFirebase)

**Hathora**
- Hathora's game-server hosting shut down on 2026-05-05 after being announced on 2026-03-04, with the team joining Fireworks AI. Stormgate lost multiplayer modes. — [Supercraft blog](https://crux.supercraft.host/blog/hathora-shut-down-where-to-go-after-may-2026/); [TechSpot](https://www.techspot.com/news/111969-stormgate-servers-go-dark-following-ai-focused-hosting.html); [Edgegap: Switch from Hathora](https://docs.edgegap.com/docs/tools-and-integrations/switch-from-hathora)

**Edgegap**
- Free tier: "1 app / 2 versions; up to 1.5 vCPU + 3 GB and 1 concurrent deployment, 60-min uptime cap per deployment", no card. On-demand: $0.00115/vCPU/minute (~$0.069/vCPU-hour) and $0.10/GB egress, "$0 when idle", minimum $1 charge in any month with deployments. The page links a Godot Engine integration. — [Edgegap pricing](https://edgegap.com/pricing)

**Rivet**
- Free $0: 100,000 Awake Actor Hours/month, 100 GB egress, 1 vCPU ($5/month compute cap). Hobby $20/month + usage: 400k actor-hours, 1 TB egress, 8 vCPU. Team $200/month. Usage: $0.05 per 1k actor-hours, $0.15/GB egress, $0.20/M reads, $1/M writes. The page has no date and doesn't mention Godot. — [Rivet Cloud](https://rivet.dev/cloud/)

**W4 Cloud (Godot-specific)**
- W4 Games launched W4 Cloud in March 2024 for Godot: auth, a Supabase/PostgREST-based DB, lobbies, matchmaking, and Agones-based dedicated servers. It is AGPL open source and self-hostable at no cost. Hosted pricing wasn't disclosed at launch. — [W4 Games announcement](https://w4games.com/2024/03/05/w4-cloud-is-here-the-new-multiplayer-infrastructure-for-godot-games); [GameFromScratch](https://gamefromscratch.com/w4-games-launch-w4-cloud-complete-godot-multiplayer-solution/)

### Inferences
- **Ably's 50 msg/s per-connection outbound limit is a likely blocker for design (a).** The teacher's single connection would receive 40 phones x 2 bundles/s = 80 msg/s. This assumes "outbound" means Ably-to-client, which is Ably's usual meaning but wasn't spelled out on the page. Its 50/s per-channel publish limit likewise blocks a server publishing 200-400 msg/s on one channel in design (b), which would have to batch or shard channels.
- Cloudflare DO: a ticking server (design b) or an always-busy relay can't hibernate, so it is billed duration for the whole session. That is 3,600 s x 0.125 GB = 450 GB-s per hour, far below 13,000 GB-s/day free.
- PartyKit is no longer a separate hosted product with its own pricing. It now means Durable Objects on your own Cloudflare account.
- Edgegap's free tier (1 deployment, 60-min cap) could technically host one under-1-hour class session at a time with a headless Godot server. A session that runs over 60 min would be killed.
- W4 Cloud would duplicate Supabase, which the project already uses, and its 2026 hosted status is unknown.

### Gaps
- I didn't verify whether Ably's $29 Standard base includes any message allowance.
- I found no official Godot SDK for Ably, Pusher, Rivet or Cloudflare DO; raw `WebSocketPeer` is assumed. I didn't verify Pusher's public WebSocket protocol doc or Ably's raw protocol suitability.
- Rivet's 2026 product direction (game servers vs "actors") and any Godot plugin couldn't be confirmed.
- I couldn't find W4 Cloud's 2026 status or hosted pricing (w4games.com/w4cloud returned 404).
- Hathora sources are secondary (vendor blogs and news); I didn't fetch Hathora's own announcement.
- I didn't fetch Edgegap's free-tier egress allowance.

---

## 6. Rough monthly cost for 40 players x 3 sessions/day x 30-60 min, at (a) 165-215 msg/s and (b) a server snapshot per player at 5-10 Hz

### Takeaway
For services billed per delivered message (Supabase, Ably, Pusher), design (a) costs about **$50-$145/month** and design (b) about **$100-$315/month**. For services billed on compute or bandwidth (Cloudflare DO, Colyseus Cloud, Edgegap, Photon 100 CCU), either design costs **$0-$40/month**, and DO likely stays on the free plan. Supabase Free cannot carry either design.

### Cited Findings
- Volume arithmetic uses the assumptions at the top; the unit prices come from sections 1-5:
  - Supabase: $25 Pro, 5 M included, $2.50/M — [Supabase pricing](https://supabase.com/pricing)
  - Ably: $29 + $2.50/M — [Ably pricing](https://ably.com/pricing)
  - Pusher: daily plans — [Pusher pricing](https://pusher.com/channels/pricing/)
  - Firebase: $1/GB after 10 GB — [Firebase pricing](https://firebase.google.com/pricing)
  - Cloudflare DO: 100k requests/day free, 20:1, outgoing free, 128 MB duration — [Cloudflare DO pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/)
  - Photon: $95 for 12 months, 300 GB/month — [Photon pricing](https://www.photonengine.com/pricing)
  - Colyseus: $15 flat, unlimited bandwidth — [Colyseus pricing](https://colyseus.io/pricing)
  - Edgegap: $0.069/vCPU-h, $0.10/GB — [Edgegap pricing](https://edgegap.com/pricing)
  - Rivet: free 100 GB egress, Hobby $20 — [Rivet Cloud](https://rivet.dev/cloud/)

### Inferences
**Volume**
- (a) 165-215 msg/s is 0.59-0.77 M messages per session-hour. Over 33-66 h/month that is **19.6-51.1 M messages/month**, or 0.9-2.3 M/day.
- (b) 280-480 msg/s is 1.0-1.7 M messages per session-hour, so **33-114 M/month**, or 1.5-5.2 M/day.
- Bandwidth for (a), snapshot fan-out only: 2.6-3.5 KB x 3/s x 40 is about 1.1-1.5 GB/h, or **37-99 GB/month** before phone uploads and protocol overhead.
- Bandwidth for (b) with full JSON snapshots (~3.5 KB per player per tick) is 2.5-5 GB/h, or **83-330 GB/month**. With a compact binary or delta snapshot (~0.5 KB) it is 0.36-0.72 GB/h, or about 12-48 GB/month.

| Service | (a) current hub, ~monthly | (b) server snapshot 5-10 Hz, ~monthly | Hard blocker / note |
|---|---|---|---|
| Supabase Free | Not viable | Not viable | 100 msg/s limit; 2 M/month gone in ~3.4 h of play |
| Supabase Pro, cap on | $25, but Realtime stops after ~8.4 h of play | $25, stops after ~3-5 h | Usage disallowed once 5 M is spent |
| Supabase Pro, cap off | **~$62-$143** | **~$98-$300** | 2,500 msg/s limit (500 if capped) |
| Ably Standard | ~$78-$157 | ~$112-$314 | 50 msg/s per connection and per channel; Free's 6 M/month lasts ~10 h |
| Pusher | Startup $49 (low end) to Pro $99 | Pro $99 to Business $299 | Sandbox 200k/day lasts ~20 min at 165 msg/s |
| Firebase RTDB (Blaze) | ~$27-$89 download | ~$73-$320 (JSON), ~$2-$38 (binary) | Spark 10 GB/month lasts ~7-9 h; not pub/sub |
| Cloudflare DO | **$0 (free plan)** | **$0 free at 2 Hz input**; ~$5 Paid if input at 10 Hz | You write a JS/TS relay or server |
| Photon 100 CCU | ~$7.90 amortized ($95/yr) | ~$7.90 + overage if over 300 GB at $0.10/GB | Free 20 CCU too small; Godot SDK is a preview |
| Colyseus Cloud | $15 | $15 | No free tier; beta Godot GDExtension |
| Edgegap on-demand | n/a (needs headless server) | ~$4.55 compute (66 h x 1 vCPU) + $1-$33 egress | Free tier: 1 deployment, 60-min cap |
| Rivet | $0 (Free, under 100 GB egress) | $0-$20 (Hobby if egress over 100 GB) | TS actors; no Godot SDK |
| Nakama self-host | VM cost only | VM cost only | Second DB to run; client last tagged 2024 |
| Heroic Cloud | Unpublished (one unverified mention of ~$400) | Unpublished | Billed when idle |

**How the table rows were worked out**
- Supabase Pro, cap off: 19.6 M gives 15 packages over the quota = $37.50 + $25 = $62.50. 51.1 M gives 47 packages = $117.50 + $25 = $142.50. For (b), 33.3 M is $97.50 and 114 M is $300.
- Cloudflare DO, design (a) as a relay: about 83 incoming/s x 3,600 / 20 = ~15k billable requests per hour, or ~45k/day at 3 h, under 100k/day free. Duration is 450 GB-s/h, under 13,000/day.
- Cloudflare DO, design (b) with phone input at 10 Hz: 400 incoming/s gives 72k requests/h, or 216k/day. That is over the free 100k/day, so it needs Paid: ~4.75 M requests/month gives about $0.56 over the $5 minimum.
- Cloudflare DO overall: outgoing snapshots cost nothing in either design.
- Photon: design (a) traffic of 37-99 GB/month fits the 300 GB included.

**Ranking**
- For a solo developer already on Supabase, the cheapest robust paths are:
  1. Keep the teacher hub but move the position relay to a Cloudflare Durable Object, which is free at this scale, while Supabase keeps accounts, RPC scoring and gems.
  2. Stay on Supabase Pro with the spend cap off, at about $60-$145/month for (a).
- Per-delivery billing (Supabase, Ably, Pusher) makes design (b) 1.5-2x more expensive than (a). Compute-billed services are indifferent to the message count.

### Gaps
- All figures are estimates from list prices. Real Supabase counts for 40 students weren't measured; 215 msg/s is the brief's bound, not a measurement.
- Phone upload bundle size is unknown, so upload bandwidth is excluded.
- The school-day count (22/month) is an assumption.
- Taxes, the Supabase compute add-on beyond the $10 credit, and Colyseus plan sizing are not included.
