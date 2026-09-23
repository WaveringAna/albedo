package daemon

import (
	"strings"
	"testing"
	"time"
)

func TestAssistantAge(t *testing.T) {
	now := time.Unix(2000000000, 0)

	cases := []struct {
		offset int64
		label  string
	}{
		{0, "just now"},
		{59, "just now"},
		{60, "1m ago"},
		{3599, "59m ago"},
		{3600, "1h ago"},
		{86400, "1d ago"},
		{-10, "just now"},
	}

	for _, tc := range cases {
		ts := now.Unix() - tc.offset
		if res := AssistantAge(&ts, now); res != tc.label {
			t.Errorf("for offset %d: expected %s, got %s", tc.offset, tc.label, res)
		}
	}

	if res := AssistantAge(nil, now); res != "time unknown" {
		t.Errorf("expected time unknown for nil, got %s", res)
	}
}

func TestSessionListing(t *testing.T) {
	now := time.Unix(2000000000, 0)
	ts := now.Unix() - 120

	session := Session{
		ID:              "deadbeef1234",
		Title:           "fix the session picker",
		Workspace:       "/tmp",
		Model:           "fixture",
		Provider:        "fixture",
		Protocol:        "responses",
		LastAssistantAt: &ts,
	}

	listing := SessionListing([]Session{session}, now)
	expected := "fix the session picker  [deadbeef]\n  last assistant: 2m ago"
	if listing != expected {
		t.Fatalf("expected:\n%s\ngot:\n%s", expected, listing)
	}

	if res := SessionListing(nil, now); res != "no sessions" {
		t.Fatalf("expected no sessions, got %s", res)
	}

	nilTsSession := session
	nilTsSession.LastAssistantAt = nil
	if !strings.Contains(SessionListing([]Session{nilTsSession}, now), "time unknown") {
		t.Fatalf("expected time unknown in listing")
	}

	dirtySession := session
	dirtySession.Title = "line\nbreak\x1b"
	if strings.Contains(SessionListing([]Session{dirtySession}, now), "\x1b") {
		t.Fatalf("expected escape code to be stripped")
	}

	unicodeSession := session
	unicodeSession.Title = "fix 👩‍💻 unicode"
	if !strings.Contains(SessionListing([]Session{unicodeSession}, now), "fix 👩‍💻 unicode") {
		t.Fatalf("expected unicode to be preserved")
	}
}
