package contracts

import (
	"errors"
	"reflect"
	"testing"
)

func TestOldResultRejectedBeforeNewDebounce(t *testing.T) {
	var s searchState
	a := s.change("a")
	if !s.begin(a) {
		t.Fatal("first request not admitted")
	}
	b := s.change("b")
	before := s
	if s.finish(a, []string{"old"}, nil) {
		t.Fatal("old result accepted during new debounce")
	}
	if !reflect.DeepEqual(before, s) {
		t.Fatal("rejected result mutated state")
	}
	if !s.begin(b) || !s.finish(b, []string{"new"}, nil) {
		t.Fatal("new request failed")
	}
	if s.phase != ready || !reflect.DeepEqual(s.rows, []string{"new"}) {
		t.Fatalf("unexpected final state: %+v", s)
	}
}

func TestStaleFailureCannotOverwriteSuccess(t *testing.T) {
	var s searchState
	a := s.change("a")
	s.begin(a)
	b := s.change("b")
	s.begin(b)
	s.finish(b, []string{"new"}, nil)
	before := s
	if s.finish(a, nil, errors.New("old failure")) || !reflect.DeepEqual(before, s) {
		t.Fatal("stale failure changed successful state")
	}
}

func TestStaleCompletionCannotStopNewLoading(t *testing.T) {
	var s searchState
	a := s.change("a")
	s.begin(a)
	b := s.change("b")
	s.begin(b)
	if s.finish(a, nil, nil) || s.phase != loading {
		t.Fatal("stale completion stopped the new loading state")
	}
}

func TestOldDebounceRejected(t *testing.T) {
	var s searchState
	a := s.change("a")
	b := s.change("b")
	if s.begin(a) || !s.begin(b) {
		t.Fatal("incorrect debounce ownership")
	}
}

func TestDuplicateBeginAndCompletionRejected(t *testing.T) {
	var s searchState
	g := s.change("query")
	if !s.begin(g) || s.begin(g) {
		t.Fatal("request admission is not single-use")
	}
	if !s.finish(g, []string{"first"}, nil) || s.finish(g, []string{"duplicate"}, nil) {
		t.Fatal("request completion is not single-use")
	}
}

func TestSameQueryRetryGetsNewIdentity(t *testing.T) {
	var s searchState
	a := s.change("query")
	s.begin(a)
	s.finish(a, nil, errors.New("transient"))
	b := s.change("query")
	if b == a || s.err != nil || !s.begin(b) || !s.finish(b, []string{"ok"}, nil) {
		t.Fatalf("retry failed: %+v", s)
	}
}

func TestEmptyResultIsReadyNotFailure(t *testing.T) {
	var s searchState
	g := s.change("no matches")
	s.begin(g)
	if !s.finish(g, nil, nil) || s.phase != ready || s.err != nil || len(s.rows) != 0 {
		t.Fatalf("empty successful result misclassified: %+v", s)
	}
}

func TestStopRejectsCompletions(t *testing.T) {
	var s searchState
	g := s.change("query")
	s.begin(g)
	s.stop()
	if s.finish(g, []string{"late"}, nil) || s.phase != stopped {
		t.Fatal("stopped owner accepted completion")
	}
}

func TestAcceptedRowsDoNotAliasCallerSlice(t *testing.T) {
	var s searchState
	g := s.change("query")
	s.begin(g)
	rows := []string{"before"}
	s.finish(g, rows, nil)
	rows[0] = "after" // Sequential mutation, not a concurrent ownership test.
	if s.rows[0] != "before" {
		t.Fatal("stored rows alias caller slice")
	}
}

func TestResultBeforeBeginRejected(t *testing.T) {
	var s searchState
	g := s.change("query")
	if s.finish(g, []string{"unexpected"}, nil) || s.phase != debouncing {
		t.Fatal("accepted a result before admitting its request")
	}
}

func TestBodyRows(t *testing.T) {
	cases := []struct {
		name                  string
		total, header, footer int
		want                  int
		compact               bool
	}{
		{"normal", 24, 3, 2, 19, false},
		{"exact", 5, 3, 2, 0, false},
		{"header-too-tall", 2, 3, 1, 0, true},
		{"footer-too-tall", 5, 3, 3, 0, true},
		{"zero-with-chrome", 0, 1, 1, 0, true},
		{"zero-empty", 0, 0, 0, 0, false},
		{"negative-size", -1, 1, 1, 0, true},
		{"negative-chrome", 5, -2, -3, 5, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, compact := bodyRows(tc.total, tc.header, tc.footer)
			if got != tc.want || compact != tc.compact {
				t.Fatalf("got (%d, %v), want (%d, %v)", got, compact, tc.want, tc.compact)
			}
		})
	}
}
