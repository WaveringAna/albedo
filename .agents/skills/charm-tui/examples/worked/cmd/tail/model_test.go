package main

import (
	"context"
	"testing"
)

func TestClosedStreamIsNotRearmed(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ch := make(chan string)
	close(ch)
	m := &model{ctx: ctx, cancel: cancel, events: ch, history: newHistory(32), width: 80, height: 24}
	msg := m.Init()()
	_, cmd := m.Update(msg)
	if !m.ended || cmd != nil {
		t.Fatal("closed stream re-armed")
	}
	_, cmd = m.Update(lineMsg("late"))
	if cmd != nil || m.history.next != 0 {
		t.Fatal("late event revived closed stream")
	}
}
