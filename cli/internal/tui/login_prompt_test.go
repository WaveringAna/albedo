package tui

import (
	"testing"

	"albedo/cli/internal/daemon"
)

func TestRevokedSignInOpensLoginOnlyForTurnsSentHere(t *testing.T) {
	revoked := daemon.StreamEvent{Type: daemon.EventError, Text: "ChatGPT sign-in for a@b.c was revoked and has been removed; run /login"}

	replayed := NewChatModel(&daemon.Session{ID: "s"}, nil)
	replayed.handleStreamEvent(revoked)
	if replayed.loginRequested {
		t.Fatal("a replayed error from an earlier attach must not open /login")
	}

	live := NewChatModel(&daemon.Session{ID: "s"}, nil)
	live.sentHere = true
	live.handleStreamEvent(daemon.StreamEvent{Type: daemon.EventError, Text: "HttpError(500, \"\")"})
	if live.loginRequested {
		t.Fatal("an unrelated error must not open /login")
	}
	live.handleStreamEvent(revoked)
	if !live.loginRequested {
		t.Fatal("a revoked sign-in during a turn sent here should open /login")
	}
}
