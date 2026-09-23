package main

import (
	"context"
	"fmt"
	"time"
)

// Every send and wait participates in the same root lifetime. The bounded
// channel provides backpressure; records are not dropped to keep drawing fast.
func produce(ctx context.Context, count int, interval time.Duration) <-chan string {
	ch := make(chan string, 16)
	go func() {
		defer close(ch)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for i := 1; i <= count; i++ {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
			line := fmt.Sprintf("event %03d · worker completed a unit of work", i)
			select {
			case <-ctx.Done():
				return
			case ch <- line:
			}
		}
	}()
	return ch
}
func receive(ctx context.Context, ch <-chan string) (string, bool) {
	select {
	case <-ctx.Done():
		return "", false
	case line, ok := <-ch:
		return line, ok
	}
}
