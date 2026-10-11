package tui

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"

	"albedo/cli/internal/daemon"

	tea "charm.land/bubbletea/v2"
)

type QuotaCancelMsg struct{}

type quotaLoadedMsg struct {
	Err      error
	Readings []daemon.QuotaObservation
	At       time.Time
	Gen      int
}

// quotaHistoryMsg is the readings of one limit over the span the pane draws,
// oldest first.
type quotaHistoryMsg struct {
	Err    error
	Key    string
	Points []quotaPoint
	Gen    int
}

// quotaTrail is what the pane knows of a limit's past: the readings, that they
// could not be had, or that they were asked for and have not come.
type quotaTrail struct {
	points  []quotaPoint
	failed  bool
	pending bool
}

// QuotaModel shows the latest reading of every limit of every account the
// daemon polls, with the highlighted limit's recent past beside it.
type QuotaModel struct {
	Conn     *daemon.Connection
	readings []daemon.QuotaObservation
	trails   map[string]quotaTrail
	at       time.Time // when the readings were fetched; every age and countdown is against it
	pageStatus
	listView
}

func NewQuotaModel(conn *daemon.Connection) QuotaModel {
	return QuotaModel{
		Conn:       conn,
		trails:     map[string]quotaTrail{},
		pageStatus: newPageStatus(true),
		listView:   newListView("Search accounts and limits"),
	}
}

func (m *QuotaModel) SetSize(width, height int) {
	m.pageStatus.SetSize(width, height)
	m.listView.setSize(width, height)
}

func (m QuotaModel) Init() tea.Cmd { return m.loadCmd(m.Generation) }

func (m QuotaModel) load() (QuotaModel, tea.Cmd) {
	m.Loading, m.Error = true, ""
	m.Generation = nextPageGeneration()
	return m, m.loadCmd(m.Generation)
}

func (m QuotaModel) loadCmd(gen int) tea.Cmd {
	return func() tea.Msg {
		if m.Conn == nil {
			return quotaLoadedMsg{Err: errors.New("daemon connection unavailable"), Gen: gen}
		}
		readings, err := daemon.GetLatestQuota(context.Background(), m.Conn)
		return quotaLoadedMsg{Readings: readings, Err: err, At: time.Now(), Gen: gen}
	}
}

// fetchTrail asks for the trail of the limit under the cursor, once: a limit
// with nothing to draw (it failed, or reported no percent) has no past to ask
// for, and one already asked for waits for its answer.
func (m *QuotaModel) fetchTrail() tea.Cmd {
	r, ok := m.current()
	if !ok || m.Loading || r.Error != nil || r.UsedPercent == nil {
		return nil
	}
	key := quotaKey(r)
	if _, asked := m.trails[key]; asked {
		return nil
	}
	m.trails[key] = quotaTrail{pending: true}
	return m.trailCmd(r, m.Generation)
}

// trailSince is how far back a limit's trail is read: as far as the pane draws.
func (m QuotaModel) trailSince(r daemon.QuotaObservation) time.Time {
	return m.at.Add(-quotaTrailSpan(r))
}

func (m QuotaModel) trailCmd(r daemon.QuotaObservation, gen int) tea.Cmd {
	key, since := quotaKey(r), m.trailSince(r)
	return func() tea.Msg {
		if m.Conn == nil {
			return quotaHistoryMsg{Err: errors.New("daemon connection unavailable"), Key: key, Gen: gen}
		}
		readings, err := daemon.GetQuotaTrail(context.Background(), m.Conn, daemon.QuotaTrailQuery{
			Provider: r.Provider, Account: r.AccountID, Limit: r.LimitID, Since: since,
		})
		return quotaHistoryMsg{Points: quotaPoints(readings), Err: err, Key: key, Gen: gen}
	}
}

// quotaPoints are the readings that carry a percent and a time, in the order
// they came.
func quotaPoints(readings []daemon.QuotaObservation) []quotaPoint {
	points := make([]quotaPoint, 0, len(readings))
	for _, r := range readings {
		if at, ok := parseStamp(r.ObservedAt); ok && r.UsedPercent != nil {
			points = append(points, quotaPoint{At: at, Percent: *r.UsedPercent})
		}
	}
	return points
}

// current is the reading under the cursor.
func (m QuotaModel) current() (daemon.QuotaObservation, bool) {
	row, ok := m.highlighted()
	if !ok {
		return daemon.QuotaObservation{}, false
	}
	i := slices.IndexFunc(m.readings, func(r daemon.QuotaObservation) bool { return quotaKey(r) == row.key })
	if i < 0 {
		return daemon.QuotaObservation{}, false
	}
	return m.readings[i], true
}

// setReadings groups the limits by provider and account, which the daemon
// does not: it orders by account alone.
func (m *QuotaModel) setReadings(readings []daemon.QuotaObservation, at time.Time) {
	m.readings = slices.Clone(readings)
	slices.SortStableFunc(m.readings, func(a, b daemon.QuotaObservation) int {
		return strings.Compare(quotaSection(a), quotaSection(b))
	})
	m.at = at
	m.rebuild()
}

func (m *QuotaModel) rebuild() {
	rows := make([]listEntry, len(m.readings))
	for i, r := range m.readings {
		rows[i] = m.entry(r)
	}
	m.setRows(rows)
}

func (m QuotaModel) entry(r daemon.QuotaObservation) listEntry {
	return listEntry{
		key:     quotaKey(r),
		section: quotaSection(r),
		name:    quotaName(r),
		desc:    quotaDesc(r),
		tag:     quotaTag(r, m.at),
		search:  []string{r.Provider, r.AccountID, r.LimitID},
		detail:  func(width int) []string { return m.details(r, width) },
	}
}

// Update asks for the highlighted limit's trail after whatever else the
// message did, so moving the cursor onto a limit is what loads its past.
func (m QuotaModel) Update(msg tea.Msg) (QuotaModel, tea.Cmd) {
	if key, ok := msg.(tea.KeyPressMsg); ok && (key.String() == "esc" || key.String() == "ctrl+c") {
		return m, func() tea.Msg { return QuotaCancelMsg{} }
	}
	m, cmd := m.update(msg)
	if trail := m.fetchTrail(); trail != nil {
		cmd = tea.Batch(cmd, trail)
	}
	return m, cmd
}

func (m QuotaModel) update(msg tea.Msg) (QuotaModel, tea.Cmd) {
	switch msg := msg.(type) {
	case quotaLoadedMsg:
		if !m.settle(msg.Gen, msg.Err, &m.Loading) {
			return m, nil
		}
		m.trails = map[string]quotaTrail{}
		m.setReadings(msg.Readings, msg.At)
		return m, nil

	case quotaHistoryMsg:
		if msg.Gen != m.Generation {
			return m, nil
		}
		m.trails[msg.Key] = quotaTrail{points: msg.Points, failed: msg.Err != nil}
		m.rebuild()
		return m, nil

	case tea.KeyPressMsg:
		if msg.String() == "ctrl+r" {
			if !m.Loading {
				return m.load()
			}
			return m, nil
		}
	}
	cmd := m.listView.update(msg)
	return m, cmd
}
