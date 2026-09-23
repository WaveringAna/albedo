package main

import (
	"fmt"
	"testing"
)

func seeded(n, capacity, height int) history {
	h := newHistory(capacity)
	for i := 0; i < n; i++ {
		h.append(fmt.Sprint(i), height)
	}
	return h
}
func TestIncomingEventPreservesReadingAnchor(t *testing.T) {
	h := seeded(8, 20, 3)
	h.scroll(-2, 3)
	before := h.top
	first := h.visible(3)[0]
	h.append("new", 3)
	if h.top != before || h.visible(3)[0] != first || h.unseen != 1 || h.follow {
		t.Fatal("new event moved reader")
	}
	h.latest(3)
	if !h.follow || h.unseen != 0 || h.visible(3)[2] != "new" {
		t.Fatal("latest did not restore following")
	}
}
func TestEvictionMarksLostAnchor(t *testing.T) {
	h := seeded(5, 5, 2)
	h.scroll(-99, 2)
	h.append("5", 2)
	if h.first != 1 || h.top != 1 || !h.expired || h.visible(2)[0] != "1" {
		t.Fatalf("%+v", h)
	}
}
func TestRingBoundAndOrder(t *testing.T) {
	h := seeded(10_000, 32, 8)
	if len(h.buf) != 32 || h.next-h.first != 32 || h.visible(8)[7] != "9999" {
		t.Fatal("ring grew or changed order")
	}
}
func TestResizeKeepsFollowState(t *testing.T) {
	h := seeded(8, 20, 3)
	h.scroll(-1, 3)
	h.resize(5)
	if h.follow {
		t.Fatal("resize enabled follow")
	}
	h.append("8", 5)
	if h.follow || h.unseen != 1 {
		t.Fatal("resize lost reading intent")
	}
	h.latest(2)
	h.resize(4)
	if h.top != h.bottom(4) {
		t.Fatal("following resize not at tail")
	}
}
func TestZeroAndTinyWindows(t *testing.T) {
	h := newHistory(0)
	if len(h.visible(0)) != 0 {
		t.Fatal("unexpected records")
	}
	h.append("a", 0)
	h.append("b", 0)
	h.scroll(-99, 0)
	h.resize(0)
	if len(h.visible(0)) != 0 || len(h.buf) != 1 || h.visible(1)[0] != "b" {
		t.Fatal("tiny window invalid")
	}
}
func TestScrollingBackToBottomFollows(t *testing.T) {
	h := seeded(8, 20, 3)
	h.scroll(-2, 3)
	h.append("8", 3)
	h.scroll(99, 3)
	if !h.follow || h.unseen != 0 {
		t.Fatal("reaching bottom did not follow")
	}
}
