package main

import (
	"fmt"
	"io"
	"strings"
)

type item struct{ ID, Label, Detail string }

type selection struct {
	items   []item
	visible []int // Indexes into items; never the identity returned to a caller.
	cursor  int
}

func newSelection(items []item) selection {
	s := selection{items: append([]item(nil), items...)}
	s.filter("")
	return s
}

func (s *selection) current() (item, bool) {
	if s.cursor < 0 || s.cursor >= len(s.visible) {
		return item{}, false
	}
	return s.items[s.visible[s.cursor]], true
}

func (s *selection) filter(query string) {
	old, hadOld := s.current()
	s.visible = nil
	query = strings.ToLower(query)
	for i, row := range s.items {
		if strings.Contains(strings.ToLower(row.Label), query) {
			s.visible = append(s.visible, i)
		}
	}
	s.cursor = 0
	if hadOld {
		for i, index := range s.visible {
			if s.items[index].ID == old.ID {
				s.cursor = i
				break
			}
		}
	}
}

func (s *selection) move(delta int) {
	s.cursor = min(max(0, s.cursor+delta), max(0, len(s.visible)-1))
}

type outcome struct {
	Accepted, Interrupted bool
	ID                    string
}

// finish is called only after Bubble Tea has released the terminal.
// Demo policy: 0 accepted, 1 cancelled, 130 keyboard interrupt, 2 failure.
func finish(w io.Writer, result outcome) (int, error) {
	if result.Interrupted {
		return 130, nil
	}
	if !result.Accepted {
		return 1, nil
	}
	if result.ID == "" {
		return 2, fmt.Errorf("accepted result has no ID")
	}
	if _, err := fmt.Fprintln(w, result.ID); err != nil {
		return 2, err
	}
	return 0, nil
}
