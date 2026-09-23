package main

import (
	"context"
	"testing"
	"time"
)

func TestClosedChannelAndBufferedRecord(t *testing.T) {
	ch := make(chan string, 1)
	ch <- "last"
	close(ch)
	if s, ok := receive(context.Background(), ch); !ok || s != "last" {
		t.Fatal("lost last buffered record")
	}
	if _, ok := receive(context.Background(), ch); ok {
		t.Fatal("closed stream looked live")
	}
}
func TestReceiveCancellationUnblocks(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	ch := make(chan string)
	done := make(chan bool, 1)
	go func() { _, ok := receive(ctx, ch); done <- ok }()
	cancel()
	select {
	case ok := <-done:
		if ok {
			t.Fatal("cancelled receive returned a record")
		}
	case <-time.After(time.Second):
		t.Fatal("receive leaked")
	}
}
func TestProducerCancellationClosesStream(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	ch := produce(ctx, 1_000, time.Hour)
	cancel()
	select {
	case _, ok := <-ch:
		if ok {
			t.Fatal("unexpected record")
		}
	case <-time.After(time.Second):
		t.Fatal("producer leaked")
	}
}
