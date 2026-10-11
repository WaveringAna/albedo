package tui

import (
	"errors"
	"math"
	"time"

	"albedo/cli/internal/daemon"
	"albedo/cli/internal/daemon/protocol"

	tea "charm.land/bubbletea/v2"
)

// quotaNow is the clock every quota shot is drawn at, in UTC so the pictures
// do not depend on the machine.
var quotaNow = time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)

func quotaReading(provider, account, id, label string, percent float64, window string, seconds int64, resetsIn, seenAgo time.Duration) daemon.QuotaObservation {
	resets := quotaNow.Add(resetsIn).Format(time.RFC3339)
	return daemon.QuotaObservation{
		Provider: provider, AccountID: account, LimitID: id, Label: label,
		UsedPercent: &percent, WindowLabel: &window, WindowSeconds: &seconds,
		ResetsAt: &resets, Status: "ok", Source: "poll",
		ObservedAt: quotaNow.Add(-seenAgo).Format(time.RFC3339),
	}
}

func quotaFixture() []daemon.QuotaObservation {
	plan := "Max 5x"
	five := quotaReading("anthropic", "dawn@example.com", "five_hour", "5 hour", 62, "5 hour", 5*3600, 2*time.Hour+14*time.Minute, 4*time.Minute)
	five.Plan = &plan
	week := quotaReading("anthropic", "dawn@example.com", "seven_day", "7 day", 23, "7 day", 7*24*3600, 4*24*time.Hour+3*time.Hour, 4*time.Minute)
	week.Plan = &plan
	hyper := quotaReading("hyper", "charm-hyper", "primary", "Primary", 85, "1 hour", 3600, 21*time.Minute, time.Minute)
	codex := quotaReading("openai-codex", "dawn-chatgpt", "primary", "5 hour", 97, "5 hour", 5*3600, 38*time.Minute, 2*time.Minute)
	stale := quotaReading("google-antigravity", "dawn@gmail.com", "gemini", "Gemini", 41, "1 day", 24*3600, 20*time.Hour, 3*time.Hour)
	broken := daemon.QuotaObservation{
		Provider: "deepseek", AccountID: "deepseek", LimitID: "balance", Label: "Balance",
		Status: "error", Source: "poll", ObservedAt: quotaNow.Add(-6 * time.Minute).Format(time.RFC3339),
		Error: &protocol.SafeReason{Code: "quota_failed", Detail: "the provider answered 401: the API key was rejected"},
	}
	return []daemon.QuotaObservation{five, week, hyper, codex, stale, broken}
}

// quotaTrailFixture is a limit's readings every ten minutes over its trail:
// in each window the percent climbs from nothing toward that window's peak
// and falls back at the reset. The newest window ends at the reading itself.
func quotaTrailFixture(r daemon.QuotaObservation) []quotaPoint {
	window := float64(*r.WindowSeconds) * float64(time.Second)
	resets, _ := resetOf(r)
	seen, _ := parseStamp(r.ObservedAt)
	// windowsBack counts whole windows between at and the one the reset closes.
	phase := func(at time.Time) (back int, progress float64) {
		x := float64(resets.Sub(at)) / window
		return int(math.Floor(x)), 1 - (x - math.Floor(x))
	}
	_, now := phase(seen)
	peaks := []float64{0, 71, 44, 88, 52, 36, 64, 79}
	var points []quotaPoint
	for at := seen.Add(-quotaTrailSpan(r)); !at.After(seen); at = at.Add(10 * time.Minute) {
		back, progress := phase(at)
		peak := peaks[back%len(peaks)]
		if back == 0 {
			peak = *r.UsedPercent / max(now, 0.05)
		}
		points = append(points, quotaPoint{At: at, Percent: min(100, peak*progress)})
	}
	return points
}

func quotaModel(width, height int) QuotaModel {
	m := NewQuotaModel(nil)
	m.SetSize(width, height)
	m, _ = m.Update(quotaLoadedMsg{Gen: m.Generation, At: quotaNow, Readings: quotaFixture()})
	return m
}

// quotaWithTrails is a screen whose limits have all had their history read.
func quotaWithTrails(width, height int) QuotaModel {
	m := quotaModel(width, height)
	for _, r := range m.readings {
		if r.UsedPercent != nil {
			m, _ = m.Update(quotaHistoryMsg{Gen: m.Generation, Key: quotaKey(r), Points: quotaTrailFixture(r)})
		}
	}
	return m
}

func quotaShot(model func(width, height int) QuotaModel, keys ...tea.Msg) func(width, height int) string {
	return func(width, height int) string {
		m := model(width, height)
		for _, key := range keys {
			m, _ = m.Update(key)
		}
		return m.View()
	}
}

func init() {
	down := tea.KeyPressMsg{Code: tea.KeyDown}
	registerShots("quota",
		shotState{"list", quotaShot(quotaWithTrails)},
		shotState{"warm", quotaShot(quotaWithTrails, down, down, down, down)},
		shotState{"hot", quotaShot(quotaWithTrails, down, down, down, down, down)},
		shotState{"stale", quotaShot(quotaWithTrails, down, down, down)},
		shotState{"failed", quotaShot(quotaWithTrails, down, down)},
		shotState{"history-loading", quotaShot(quotaModel)},
		shotState{"filtering", quotaShot(quotaWithTrails, shotTyped("hyper")...)},
		shotState{"no-match", quotaShot(quotaWithTrails, shotTyped("zzz")...)},
		shotState{"loading", func(width, height int) string {
			m := NewQuotaModel(nil)
			m.SetSize(width, height)
			return m.View()
		}},
		shotState{"empty", func(width, height int) string {
			m := NewQuotaModel(nil)
			m.SetSize(width, height)
			m, _ = m.Update(quotaLoadedMsg{Gen: m.Generation, At: quotaNow})
			return m.View()
		}},
		shotState{"load-failed", func(width, height int) string {
			m := NewQuotaModel(nil)
			m.SetSize(width, height)
			m, _ = m.Update(quotaLoadedMsg{Gen: m.Generation, Err: errors.New("daemon connection unavailable")})
			return m.View()
		}},
	)
}
