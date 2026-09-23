package main

import (
	"bytes"
	"errors"
	"testing"
)

func testItems() []item {
	return []item{{"a", "alpha", ""}, {"b", "beta", ""}, {"c", "beta clone", ""}}
}

func TestFilterPreservesIdentity(t *testing.T) {
	s := newSelection(testItems())
	s.move(1)
	s.filter("beta")
	row, ok := s.current()
	if !ok || row.ID != "b" || s.cursor != 0 {
		t.Fatalf("%+v", s)
	}
	s.filter("")
	row, _ = s.current()
	if row.ID != "b" || s.cursor != 1 {
		t.Fatal("lost identity when clearing search")
	}
}

func TestEmptyAndNoMatchesAreSafe(t *testing.T) {
	for _, items := range [][]item{nil, testItems()} {
		s := newSelection(items)
		s.filter("not present")
		s.move(99)
		s.move(-99)
		if _, ok := s.current(); ok {
			t.Fatal("empty list produced a selection")
		}
	}
}

func TestDuplicateLabelsKeepDistinctIDs(t *testing.T) {
	s := newSelection([]item{{"one", "same", ""}, {"two", "same", ""}})
	s.move(1)
	s.filter("same")
	row, _ := s.current()
	if row.ID != "two" {
		t.Fatal("used label as identity")
	}
}

func TestConstructorOwnsItsItems(t *testing.T) {
	rows := testItems()
	s := newSelection(rows)
	rows[0].Label = "mutated"
	row, _ := s.current()
	if row.Label != "alpha" {
		t.Fatal("shared mutable input")
	}
}

func TestFinishNeverLeaksCancelledSelection(t *testing.T) {
	for _, c := range []struct {
		result outcome
		code   int
		out    string
	}{
		{outcome{Accepted: true, ID: "b"}, 0, "b\n"},
		{outcome{ID: "b"}, 1, ""},
		{outcome{Accepted: true, Interrupted: true, ID: "b"}, 130, ""},
	} {
		var out bytes.Buffer
		code, err := finish(&out, c.result)
		if err != nil || code != c.code || out.String() != c.out {
			t.Fatalf("code=%d err=%v output=%q", code, err, out.String())
		}
	}
}

type brokenWriter struct{}

func (brokenWriter) Write([]byte) (int, error) { return 0, errors.New("broken pipe") }
func TestFinishReportsWriteAndInvalidResult(t *testing.T) {
	if code, err := finish(brokenWriter{}, outcome{Accepted: true, ID: "b"}); code != 2 || err == nil {
		t.Fatal("lost write error")
	}
	var out bytes.Buffer
	if code, err := finish(&out, outcome{Accepted: true}); code != 2 || err == nil || out.Len() != 0 {
		t.Fatal("empty ID emitted")
	}
}
