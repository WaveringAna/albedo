package tui

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestSplitMouseReportsBecomeMouseEvents(t *testing.T) {
	filter := RepairSplitMouse()
	altBracket := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'['}, Alt: true}
	tail := func(s string) tea.KeyMsg { return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)} }

	if filter(nil, altBracket) != nil {
		t.Fatal("the split prefix reached the model")
	}
	got, ok := filter(nil, tail("<64;19;5M")).(tea.MouseMsg)
	if !ok || got.Button != tea.MouseButtonWheelUp || got.X != 18 || got.Y != 4 {
		t.Fatalf("wheel up not rebuilt: %#v", got)
	}
	filter(nil, altBracket)
	if got, _ := filter(nil, tail("<65;1;1M")).(tea.MouseMsg); got.Button != tea.MouseButtonWheelDown {
		t.Fatalf("wheel down not rebuilt: %#v", got)
	}
	filter(nil, altBracket)
	if got, _ := filter(nil, tail("<0;10;3m")).(tea.MouseMsg); got.Action != tea.MouseActionRelease {
		t.Fatalf("release not rebuilt: %#v", got)
	}
	// Ordinary typing is untouched, including the same text without the prefix.
	for _, msg := range []tea.Msg{tail("<64;19;5M"), tail("hello"), tea.KeyMsg{Type: tea.KeyEnter}} {
		if got := filter(nil, msg); got == nil {
			t.Fatalf("%v was dropped", msg)
		}
		if _, isMouse := filter(nil, msg).(tea.MouseMsg); isMouse {
			t.Fatalf("%v became a mouse event", msg)
		}
	}
	filter(nil, altBracket)
	if got := filter(nil, tail("hello")); got.(tea.KeyMsg).String() != "hello" {
		t.Fatal("text after a lone alt+[ was changed")
	}
}

// chunked returns its data in fixed-size reads, like a backed-up terminal.
type chunked struct {
	data []byte
	size int
}

func (c *chunked) Read(p []byte) (int, error) {
	if len(c.data) == 0 {
		select {} // hold the program open until it quits
	}
	n := min(len(p), c.size, len(c.data))
	copy(p, c.data[:n])
	c.data = c.data[n:]
	return n, nil
}

type recorder struct {
	msgs []tea.Msg
	want int
}

func (r *recorder) Init() tea.Cmd { return nil }
func (r *recorder) View() string  { return "" }
func (r *recorder) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg.(type) {
	case tea.KeyMsg, tea.MouseMsg:
		r.msgs = append(r.msgs, msg)
		if len(r.msgs) >= r.want {
			return r, tea.Quit
		}
	}
	return r, nil
}

// Bubble Tea's own reader, fed full 256-byte reads that end inside a report.
func TestBubbleTeaReaderSplitsAreRepaired(t *testing.T) {
	var stream []byte
	for i := 0; i < 60; i++ {
		stream = append(stream, "\x1b[<64;19;5M"...)
	}
	run := func(filter bool) (mouse, keys int) {
		model := &recorder{want: 60}
		opts := []tea.ProgramOption{tea.WithInput(&chunked{data: stream, size: 256}), tea.WithoutRenderer(), tea.WithoutSignalHandler()}
		if filter {
			opts = append(opts, tea.WithFilter(RepairSplitMouse()))
		} else {
			model.want = 61 // each split adds a key
		}
		done := make(chan struct{})
		go func() { _, _ = tea.NewProgram(model, opts...).Run(); close(done) }()
		<-done
		for _, msg := range model.msgs {
			switch msg.(type) {
			case tea.MouseMsg:
				mouse++
			case tea.KeyMsg:
				keys++
			}
		}
		return mouse, keys
	}
	if mouse, keys := run(false); keys == 0 {
		t.Fatalf("expected the unfiltered reader to split a report (mouse %d)", mouse)
	}
	if mouse, keys := run(true); mouse != 60 || keys != 0 {
		t.Fatalf("filtered: %d mouse events, %d keys; want 60 and 0", mouse, keys)
	}
}
