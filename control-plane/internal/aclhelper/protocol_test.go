package aclhelper

import "testing"

func TestParseLine_SerialFraming(t *testing.T) {
	got := ParseLine("example.com\n")
	if got.Channel != "" {
		t.Fatalf("serial line must have no channel, got %q", got.Channel)
	}
	if got.Host != "example.com" {
		t.Fatalf("host = %q, want example.com", got.Host)
	}
}

func TestParseLine_ConcurrencyFraming(t *testing.T) {
	got := ParseLine("7 example.com\n")
	if got.Channel != "7" {
		t.Fatalf("channel = %q, want 7", got.Channel)
	}
	if got.Host != "example.com" {
		t.Fatalf("host = %q, want example.com", got.Host)
	}
}

func TestParseLine_URLDecode(t *testing.T) {
	// `%>ha{Host}` percent-encodes the host; the helper MUST decode it.
	got := ParseLine("3 a%2Db.example.com%3A8443\n")
	if got.Channel != "3" {
		t.Fatalf("channel = %q, want 3", got.Channel)
	}
	if got.Host != "a-b.example.com:8443" {
		t.Fatalf("host = %q, want a-b.example.com:8443 (percent-decoded)", got.Host)
	}
}

func TestParseLine_EmptyLine(t *testing.T) {
	got := ParseLine("\n")
	if got.Channel != "" || got.Host != "" {
		t.Fatalf("blank line must yield empty Request, got %+v", got)
	}
}

func TestParseLine_MalformedEncodingPreservesChannel(t *testing.T) {
	// Bad percent-escape ⇒ no usable host, but the channel is preserved so the
	// ERR reply can still be matched in concurrency mode.
	got := ParseLine("9 %zz\n")
	if got.Channel != "9" {
		t.Fatalf("channel = %q, want 9", got.Channel)
	}
	if got.Host != "" {
		t.Fatalf("malformed host must decode to empty, got %q", got.Host)
	}
}

func TestParseLine_NonNumericFirstTokenIsHost(t *testing.T) {
	// A non-digit first token is NOT a channel-id; the whole token is the host.
	got := ParseLine("host.example\n")
	if got.Channel != "" {
		t.Fatalf("non-numeric first token must not be a channel, got %q", got.Channel)
	}
	if got.Host != "host.example" {
		t.Fatalf("host = %q, want host.example", got.Host)
	}
}

func TestFormatReply(t *testing.T) {
	cases := []struct {
		name    string
		channel string
		ok      bool
		tag     string
		want    string
	}{
		{"serial OK tag", "", true, "tun_a", "OK tag=tun_a\n"},
		{"serial bare OK", "", true, "", "OK\n"},
		{"serial ERR", "", false, "", "ERR\n"},
		{"concurrency OK tag", "7", true, "tun_a", "7 OK tag=tun_a\n"},
		{"concurrency bare OK", "7", true, "", "7 OK\n"},
		{"concurrency ERR", "7", false, "", "7 ERR\n"},
		{"ERR ignores tag", "", false, "tun_a", "ERR\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := FormatReply(tc.channel, tc.ok, tc.tag); got != tc.want {
				t.Fatalf("FormatReply(%q,%v,%q) = %q, want %q", tc.channel, tc.ok, tc.tag, got, tc.want)
			}
		})
	}
}

func TestIsChannelID(t *testing.T) {
	for _, tok := range []string{"0", "7", "12345"} {
		if !isChannelID(tok) {
			t.Errorf("isChannelID(%q) = false, want true", tok)
		}
	}
	for _, tok := range []string{"", "7a", "-1", "1.0", "host"} {
		if isChannelID(tok) {
			t.Errorf("isChannelID(%q) = true, want false", tok)
		}
	}
}
