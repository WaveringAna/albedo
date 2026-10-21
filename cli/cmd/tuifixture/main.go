// Command tuifixture captures one live session's transcript into the file the
// chat benchmarks replay. It issues only the reads a TUI client makes when it
// opens a session: the snapshot and the history pages. It never writes to the
// daemon and never sends a prompt.
//
//	ALBEDO_HOME=~/.albedo go run ./cmd/tuifixture -session <id> -out /tmp/fx.json
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"albedo/cli/internal/config"
	"albedo/cli/internal/daemon"
	"albedo/cli/internal/localdaemon"
)

// capture is one session as the benchmarks replay it. The reset event a real
// stream opens with is rebuilt from Session, because its snapshot carries
// fields (glances, location) the wire type does not marshal.
type capture struct {
	CapturedAt time.Time            `json:"captured_at"`
	Session    capturedSession      `json:"session"`
	Tail       []daemon.StreamEvent `json:"tail"`
	Full       []daemon.StreamEvent `json:"full"`
}

type capturedSession struct {
	ID              string              `json:"id"`
	Title           string              `json:"title"`
	Workspace       string              `json:"workspace"`
	Model           string              `json:"model"`
	Effort          string              `json:"effort"`
	Provider        string              `json:"provider"`
	TranscriptCount int                 `json:"transcript_count"`
	Status          daemon.AgentStatus  `json:"status"`
	Glances         []daemon.PageGlance `json:"glances"`
	// Before is the first row the reset carried, and More whether rows precede it.
	Before int64 `json:"before"`
	More   bool  `json:"more"`
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	session := flag.String("session", "", "session id to capture")
	out := flag.String("out", "", "path to write the fixture to")
	pageRows := flag.Int("page", 200, "history rows per page read")
	tail := flag.Int("tail", 120, "history rows the opening stream carries")
	full := flag.Int("full", 4000, "history rows the full transcript keeps, 0 for all")
	flag.Parse()
	if *session == "" || *out == "" {
		flag.Usage()
		return fmt.Errorf("-session and -out are required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	home := config.HomeDir()
	found, err := localdaemon.Discover(ctx, home)
	if err != nil {
		return err
	}
	if found.Kind != localdaemon.Running {
		return fmt.Errorf("no running daemon under %s", home)
	}
	conn, err := daemon.Attach(ctx, found.Snapshot, nil)
	if err != nil {
		return err
	}
	defer conn.HTTPClient().CloseIdleConnections()

	client := daemon.NewChatClient(conn, *session)
	snapshot, err := client.GetSession(ctx)
	if err != nil {
		return fmt.Errorf("read session: %w", err)
	}

	// Newest page first, then backwards, so each page is prepended.
	var pages [][]daemon.StreamEvent
	before := int64(0)
	more := false
	rows := 0
	for {
		historyPage, err := client.History(ctx, before, *pageRows)
		if err != nil {
			return fmt.Errorf("read history: %w", err)
		}
		pages = append(pages, historyPage.Events)
		rows += len(historyPage.Events)
		more = historyPage.More
		if !historyPage.More || historyPage.Before == 0 {
			break
		}
		before = historyPage.Before
		if *full > 0 && rows >= *full {
			break
		}
	}

	var fullEvents []daemon.StreamEvent
	for i := len(pages) - 1; i >= 0; i-- {
		fullEvents = append(fullEvents, pages[i]...)
	}
	if *full > 0 && len(fullEvents) > *full {
		fullEvents = fullEvents[len(fullEvents)-*full:]
	}
	tailEvents := lastRows(fullEvents, *tail)
	tailStart := int64(0)
	for _, event := range tailEvents {
		if isRow(event) {
			tailStart = event.Position
			break
		}
	}

	carried := capture{
		CapturedAt: time.Now(),
		Session: capturedSession{
			ID: snapshot.ID, Title: snapshot.Title, Workspace: snapshot.Workspace,
			Model: snapshot.Model, Effort: snapshot.Effort, Provider: snapshot.Provider,
			TranscriptCount: snapshot.TranscriptCount, Status: snapshot.Status, Glances: snapshot.Glances,
			Before: tailStart, More: more || len(tailEvents) < len(fullEvents),
		},
		Tail: withoutReset(tailEvents),
		Full: withoutReset(fullEvents),
	}
	data, err := json.Marshal(carried)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(*out), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(*out, data, 0o644); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "%s: %d rows, tail %d rows, %d bytes\n", snapshot.ID, len(carried.Full), len(carried.Tail), len(data))
	return nil
}

// lastRows keeps the newest rows of a transcript, with the committed stamps
// that follow them, since a stream's tail counts transcript rows.
func lastRows(events []daemon.StreamEvent, rows int) []daemon.StreamEvent {
	if rows <= 0 {
		return events
	}
	for at := len(events) - 1; at >= 0; at-- {
		if !isRow(events[at]) {
			continue
		}
		rows--
		if rows == 0 {
			return events[at:]
		}
	}
	return events
}

// isRow reports whether an event carries a transcript row rather than a stamp.
func isRow(event daemon.StreamEvent) bool {
	switch event.Type {
	case daemon.EventUser, daemon.EventMessage, daemon.EventThinking, daemon.EventTool,
		daemon.EventNote, daemon.EventCompacted, daemon.EventError, daemon.EventTurnCompleted:
		return true
	}
	return false
}

// withoutReset drops reset events: the benchmark rebuilds the opening reset
// from the captured session so it carries the glances and status.
func withoutReset(events []daemon.StreamEvent) []daemon.StreamEvent {
	kept := make([]daemon.StreamEvent, 0, len(events))
	for _, evt := range events {
		if evt.Type == daemon.EventReset {
			continue
		}
		kept = append(kept, evt)
	}
	return kept
}
