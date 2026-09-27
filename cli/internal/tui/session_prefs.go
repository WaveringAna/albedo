package tui

import (
	"encoding/json"
	"maps"
	"os"
	"path/filepath"
	"slices"
)

// sessionPrefs keeps local picker organization and global chat display choices.
// A missing or unreadable file is treated as empty.
type sessionPrefs struct {
	Pinned   []string       `json:"pinned,omitempty"`
	Archived []string       `json:"archived,omitempty"`
	Opens    map[string]int `json:"opens,omitempty"`
	Thinking bool           `json:"thinking,omitempty"`
	Tools    bool           `json:"tools,omitempty"`
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

func (p sessionPrefs) archived(id string) bool { return slices.Contains(p.Archived, id) }

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
	drop := func(id string) bool {
		gone := !known[id]
		changed = changed || gone
		return gone
	}
	p.Pinned = slices.DeleteFunc(p.Pinned, drop)
	p.Archived = slices.DeleteFunc(p.Archived, drop)
	maps.DeleteFunc(p.Opens, func(id string, _ int) bool { return drop(id) })
	return changed
}
