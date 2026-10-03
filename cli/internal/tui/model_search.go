package tui

import (
	"albedo/cli/internal/daemon"
	"slices"
	"strings"
	"unicode"

	"github.com/sahilm/fuzzy"
)

// mergeModels lists seeds first, then the rest of listed, each id once. A
// listed entry lends its catalog facts to the seed of the same id.
func mergeModels(seeds []string, listed []daemon.Model) []daemon.Model {
	byID := make(map[string]daemon.Model, len(listed))
	for _, m := range listed {
		byID[m.ID] = m
	}
	seen := map[string]bool{"": true}
	var out []daemon.Model
	add := func(m daemon.Model) {
		if !seen[m.ID] {
			seen[m.ID] = true
			out = append(out, m)
		}
	}
	for _, id := range seeds {
		m, ok := byID[id]
		if !ok {
			m = daemon.Model{ID: id}
		}
		add(m)
	}
	for _, m := range listed {
		add(m)
	}
	return out
}

var searchNoise = strings.NewReplacer(" ", "", "-", "", "_", "", ".", "", ":", "", "/", "")

func searchKey(s string) string { return searchNoise.Replace(strings.ToLower(s)) }

// matchRank orders search matches, compared element by element: an exact id
// first, then words that start the id or one of its parts, then the fuzzy
// score. A fuzzy bonus never outweighs a word typed from the start.
type matchRank [3]int

func (a matchRank) compare(b matchRank) int { return slices.Compare(a[:], b[:]) }

// matchModel ranks a model against the search words. Each word must fuzzy
// match the model id or the profile name.
func matchModel(words []string, profile, id string) (rank matchRank, hits []int, ok bool) {
	if whole := strings.Join(words, ""); whole != "" && (whole == searchKey(id) || whole == searchKey(profile+id)) {
		rank[0] = 1
	}
	fields := []string{id, profile}
	for _, word := range words {
		var best matchRank
		var bestHits []int
		found := fuzzy.Find(word, fields)
		for i, f := range found {
			if r := (matchRank{0, startTier(fields[f.Index], word), f.Score}); i == 0 || r.compare(best) > 0 {
				best, bestHits = r, nil
				if f.Index == 0 {
					bestHits = f.MatchedIndexes
				}
			}
		}
		if len(found) == 0 {
			return matchRank{}, nil, false
		}
		rank[1] += best[1]
		rank[2] += best[2]
		hits = append(hits, bestHits...)
	}
	return rank, hits, true
}

// startTier is 2 when word starts s, 1 when it starts a part of s after a
// separator, else 0. Separators fold as in searchKey, so "gpt5" starts "gpt-5".
func startTier(s, word string) int {
	if strings.HasPrefix(searchKey(s), word) {
		return 2
	}
	for i := 1; i < len(s); i++ {
		if strings.ContainsRune(searchSeparators, rune(s[i-1])) && strings.HasPrefix(searchKey(s[i:]), word) {
			return 1
		}
	}
	return 0
}

// refilter rebuilds the rows from the catalogs and the search text. The
// cursor stays on its row unless reset.
func (m *ModelPickerModel) refilter(reset bool) {
	keep := ""
	if r, ok := m.highlighted(); ok && !reset {
		keep = r.key()
	}
	query := strings.TrimSpace(m.search.Value())
	var words []string
	for field := range strings.FieldsSeq(query) {
		if word := searchKey(field); word != "" {
			words = append(words, word)
		}
	}

	// Rows rank within their profile, and profiles by their best
	// row. Ties, and an empty search, keep the catalog order.
	type scored struct {
		row  modelRow
		rank matchRank
	}
	var groups [][]scored
	var typed []modelRow
	canType := query != "" && !strings.ContainsFunc(query, unicode.IsSpace) && validateModelID(query) == nil
	for _, c := range m.catalogs {
		var group []scored
		for _, model := range c.models {
			if rank, hits, ok := matchModel(words, c.name, model.ID); ok {
				group = append(group, scored{modelRow{profile: c.name, model: model, hits: hits}, rank})
			}
		}
		if len(group) > 0 {
			slices.SortStableFunc(group, func(a, b scored) int { return b.rank.compare(a.rank) })
			groups = append(groups, group)
		}
		// An id has no spaces, so a search of several words offers none.
		if canType && !slices.ContainsFunc(c.models, func(model daemon.Model) bool { return model.ID == query }) {
			typed = append(typed, modelRow{profile: c.name, model: daemon.Model{ID: query}, typed: true})
		}
	}
	slices.SortStableFunc(groups, func(a, b []scored) int { return b[0].rank.compare(a[0].rank) })
	m.rows = nil
	for _, group := range groups {
		for _, s := range group {
			m.rows = append(m.rows, s.row)
		}
	}
	m.rows = append(m.rows, typed...)
	m.cursor = max(0, slices.IndexFunc(m.rows, func(r modelRow) bool { return r.key() == keep }))
}
