// The shared filter ranks within a group and keeps the groups in the order
// they were listed. A session list's sections and action rows depend on that
// while a search is typed, and no e2e scenario types a query and reads the
// order back.
package tui

import (
	"slices"
	"testing"
)

func filteredIDs(m PickerModel) []string {
	var ids []string
	for _, item := range m.Filtered {
		ids = append(ids, item.ID)
	}
	return ids
}

func TestPickerFilterRanksWithinGroupsAndKeepsTheirOrder(t *testing.T) {
	items := []PickerItem{
		{ID: "loose", Label: "a long note about parsers", Group: 1},
		{ID: "tight", Label: "parse", Group: 1},
		{ID: "old", Label: "parse", Group: 2},
		{ID: "other", Label: "unrelated", Group: 2},
	}
	m := NewPickerModel("", items, true, "")
	m.SearchInput.SetValue("parse")
	m.applyFilter()
	if got := filteredIDs(m); !slices.Equal(got, []string{"tight", "loose", "old"}) {
		t.Fatalf("search order = %v, want the tight match first within its group and groups in order", got)
	}
	if len(m.Filtered[0].hits) == 0 {
		t.Fatal("the best match has no characters to highlight")
	}
	m.SearchInput.SetValue("")
	m.applyFilter()
	if got := filteredIDs(m); !slices.Equal(got, []string{"loose", "tight", "old", "other"}) {
		t.Fatalf("empty search order = %v, want the listed order", got)
	}
}
