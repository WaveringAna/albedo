package app

import (
	"context"
	"slices"

	"albedo/cli/internal/daemon"
)

// historyPageRows is how many transcript rows Read asks for at a time.
const historyPageRows = 200

// SessionTurns is the newest turns of a session's committed transcript.
type SessionTurns struct {
	Session string               `json:"session"`
	Events  []daemon.StreamEvent `json:"events"`
	Running bool                 `json:"running"`
}

// Read answers the newest turns of a session, reading older transcript pages
// until it has that many. A turn that is still running is not committed yet,
// so Running says whether more is on its way.
func (s *Service) Read(ctx context.Context, id string, turns int) (SessionTurns, error) {
	conn, err := s.Connect(ctx)
	if err != nil {
		return SessionTurns{}, err
	}
	id, err = resolveSession(ctx, conn, id)
	if err != nil {
		return SessionTurns{}, err
	}
	client := daemon.NewChatClient(conn, id)
	status, err := client.GetStatus(ctx)
	if err != nil {
		return SessionTurns{}, err
	}
	var pages [][]daemon.StreamEvent
	eventCount, turnCount := 0, 0
	var before int64
	for {
		page, err := client.History(ctx, before, historyPageRows)
		if err != nil {
			return SessionTurns{}, err
		}
		pages = append(pages, page.Events)
		eventCount += len(page.Events)
		turnCount += turnStarts(page.Events)
		if !page.More || turnCount >= turns {
			break
		}
		before = page.Before
	}
	events := make([]daemon.StreamEvent, 0, eventCount)
	for _, page := range slices.Backward(pages) {
		events = append(events, page...)
	}
	return SessionTurns{Session: id, Running: status.Running, Events: lastTurns(events, turns)}, nil
}

func turnStarts(events []daemon.StreamEvent) int {
	count := 0
	for _, event := range events {
		if event.Type == daemon.EventUser {
			count++
		}
	}
	return count
}

// lastTurns keeps the events from the start of the turns-th newest turn on.
func lastTurns(events []daemon.StreamEvent, turns int) []daemon.StreamEvent {
	for i, event := range slices.Backward(events) {
		if event.Type != daemon.EventUser {
			continue
		}
		if turns--; turns == 0 {
			return events[i:]
		}
	}
	return events
}
