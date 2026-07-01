module github.com/helixproxy/caddy-challtestsrv-dns

// Interface target (§11.4.6 — stated, not guessed):
//   libdns v0.2.x struct-based Record API (Type/Name/Value/TTL), which is what
//   certmagic.DNSProvider (== libdns.RecordAppender + libdns.RecordDeleter)
//   expects in Caddy v2.8.x (certmagic v0.21.x). This module is BUILT by xcaddy
//   against a pinned Caddy version (see ../Dockerfile.caddy, CADDY_VERSION=2.8.4);
//   xcaddy reconciles these require directives with the pinned Caddy's own module
//   graph at build time. For Caddy >= 2.10 (certmagic >= 0.22, libdns v1.0.0
//   typed-RR Record interface) the AppendRecords/DeleteRecords signatures change
//   — see caddy-challtestsrv-dns/README.md "Version compatibility".
go 1.22

require (
	github.com/caddyserver/caddy/v2 v2.8.4
	github.com/libdns/libdns v0.2.2
)
