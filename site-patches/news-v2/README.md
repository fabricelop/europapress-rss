# Site V1 v97: Noticias from V2

Target: appgprj_6ae4dcf7d7488191a574e5b649e67370,
https://ttactualidad.rainyraven22.chatgpt.site (public, owner).
This repository is NOT its source and cannot deploy it.

Adapter: news-v2-adapter.mjs. Once the Worker is deployed, its feed is
https://ttactualidad-v2-private-test.fabricelop.workers.dev/api/public-news.
It exposes up to 30 latest READY/archived current records and exact-revision
images allowed by the editor. PUB only archives in the manager; no X send.
Suppressed images and pending RE/RE-X are hidden immediately through D1.

Remaining integration in the actual Site source:
1. Open its existing source using the Sites workflow and retain audience/publication.
2. Replace only the active Noticias data loader with loadV2News(); preserve existing
   detail components, URLs, search, Hemeroteca, historical V1 data and relationships.
3. Route stable ttn2 IDs to V2 records while old IDs retain their V1 resolution.
4. Keep the last known successful list on a feed failure and show its actual age;
   do not silently revert the current list to V1 or invent a current timestamp.
5. Test Inicio/Noticias/detail/search/archive/image preference/revision changes and
   unchanged Tendencias. Publish from its own source and verify its new version.

BLOCKED HERE: no executor, filesystem or Git transport to git.chatgpt-team.site.
The Site was read, not changed. No credentials are persisted or forwarded.
