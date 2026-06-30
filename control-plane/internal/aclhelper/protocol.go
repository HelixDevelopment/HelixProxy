// Package aclhelper holds the PURE, side-effect-free logic of the Squid
// external_acl_type helper (design spec §4 component 3, docs/DYNAMIC_ROUTING.md
// §3.1/§4): the per-request route+health decision and the Squid stdin/stdout
// protocol codec. It contains NO I/O — Redis access is injected through the Bus
// interface (decide.go) so every branch is unit-testable with a fake and its
// negation is provably caught (§1.1). The cmd/acl-helper binary wires this pure
// core to real stdin/stdout + a real redis.Client.
//
// Protocol (Squid external_acl_type, docs/.../templates/README.md "concurrency"):
//   - SERIAL framing (no concurrency=N): each request line is the ACL data field
//     alone — here the URL-encoded request Host produced by `%>ha{Host}`. The
//     reply is `OK`, `OK tag=<tunnel>`, or `ERR`, one line per request.
//   - CONCURRENCY framing (concurrency=N appended by the compiler): Squid PREPENDS
//     a non-negative integer channel-id token: `<channel-id> <host>`. The helper
//     MUST echo that channel-id as the first token of its reply:
//     `<channel-id> OK tag=<tunnel>`. Replies are matched by channel-id, so a
//     serial read-decide-reply loop is protocol-correct for both framings.
//
// The Host field arrives URL-encoded (the `a` modifier in `%>ha{Host}` is 6.13's
// percent-encoding form), so a literal space can never appear inside the host
// token; that is what makes the two framings unambiguous (a 2-token line whose
// first token is all-digits is concurrency framing).
package aclhelper

import (
	"net/url"
	"strings"
)

// Request is one parsed external_acl line. Channel is "" in serial framing and
// the echoed channel-id token in concurrency framing. Host is the URL-decoded
// request Host, or "" when the line carried no usable / decodable host (which
// the decision treats as fail-closed ERR).
type Request struct {
	Channel string
	Host    string
}

// ParseLine parses one raw stdin line (with or without its trailing newline)
// into a Request. It supports BOTH serial (`<host>`) and concurrency
// (`<channel-id> <host>`) framing. A blank line yields an empty Request
// (Channel "", Host "") → fail-closed ERR. A host token that fails to
// percent-decode yields Host "" while preserving any parsed channel-id, so the
// ERR reply can still be matched back to its request in concurrency mode.
func ParseLine(line string) Request {
	line = strings.TrimRight(line, "\r\n")
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return Request{}
	}
	channel := ""
	rawHost := fields[0]
	// Concurrency framing: a leading all-digit token + at least one more token.
	// (The host is percent-encoded, so it never contains a space — a 2+ token
	// line with a numeric first token is unambiguously channel-id + host.)
	if len(fields) >= 2 && isChannelID(fields[0]) {
		channel = fields[0]
		rawHost = fields[1]
	}
	host, err := url.PathUnescape(rawHost)
	if err != nil {
		// Malformed percent-encoding → no usable host (fail-closed at Decide).
		return Request{Channel: channel}
	}
	return Request{Channel: channel, Host: strings.TrimSpace(host)}
}

// FormatReply renders the Squid reply line (including its trailing newline). When
// channel != "" it is echoed as the first token (concurrency framing). ok=true
// with a non-empty tag emits `OK tag=<tag>`; ok=true with an empty tag emits a
// bare `OK`; ok=false always emits `ERR` (the fail-closed answer).
func FormatReply(channel string, ok bool, tag string) string {
	var b strings.Builder
	if channel != "" {
		b.WriteString(channel)
		b.WriteByte(' ')
	}
	switch {
	case ok && tag != "":
		b.WriteString("OK tag=")
		b.WriteString(tag)
	case ok:
		b.WriteString("OK")
	default:
		b.WriteString("ERR")
	}
	b.WriteByte('\n')
	return b.String()
}

// isChannelID reports whether tok is a non-negative integer (Squid channel-ids
// are non-negative integers). Empty or any non-digit rune → false.
func isChannelID(tok string) bool {
	if tok == "" {
		return false
	}
	for _, r := range tok {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
