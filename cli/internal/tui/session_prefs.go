package tui

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
)

// sessionPrefs is the session list's local memory: pinned sessions in pin
// order and how often each session was opened from the list. It lives beside
// the rest of the CLI configuration; a missing or unreadable file is empty.
type sessionPrefs struct {
	Pinned []string       `json:"pinned,omitempty"`
	Opens  map[string]int `json:"opens,omitempty"`
}

func loadSessionPrefs(path string) sessionPrefs {
	var p sessionPrefs
	if path == "" {
		return p
	}
	if data, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(data, &p)
	}
	return p
}

func (p sessionPrefs) save(path string) error {
	if path == "" {
		return nil
	}
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (p sessionPrefs) pinned(id string) bool { return slices.Contains(p.Pinned, id) }

func (p *sessionPrefs) togglePin(id string) {
	if i := slices.Index(p.Pinned, id); i >= 0 {
		p.Pinned = slices.Delete(p.Pinned, i, i+1)
		return
	}
	p.Pinned = append(p.Pinned, id)
}

func (p *sessionPrefs) recordOpen(id string) {
	if p.Opens == nil {
		p.Opens = map[string]int{}
	}
	p.Opens[id]++
}

// forget drops sessions the daemon no longer lists so the file cannot grow
// without bound.
func (p *sessionPrefs) forget(known map[string]bool) bool {
	changed := false
	p.Pinned = slices.DeleteFunc(p.Pinned, func(id string) bool {
		gone := !known[id]
		changed = changed || gone
		return gone
	})
	for id := range p.Opens {
		if !known[id] {
			delete(p.Opens, id)
			changed = true
		}
	}
	return changed
}
