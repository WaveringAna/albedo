// The sessions search is a plain substring match on every word, in the order
// the sessions are listed, so a scattered run of letters never matches. No e2e
// scenario types a query and reads the list back.
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

func TestPickerFilterIsSubstringPerWordInListedOrder(t *testing.T) {
	items := []PickerItem{
		{ID: "scattered", Label: "yellow elephant hat"},
		{ID: "literal", Label: "yeh"},
		{ID: "detail", Label: "other", Detail: "/work/yeh-notes"},
	}
	m := NewPickerModel("", items, true, "")
	m.SearchInput.SetValue("yeh")
	m.applyFilter()
	if got := filteredIDs(m); !slices.Equal(got, []string{"literal", "detail"}) {
		t.Fatalf("search = %v, want only the literal matches, in listed order", got)
	}
	m.SearchInput.SetValue("OTHER yeh")
	m.applyFilter()
	if got := filteredIDs(m); !slices.Equal(got, []string{"detail"}) {
		t.Fatalf("two words = %v, want only the item containing both", got)
	}
	m.SearchInput.SetValue("")
	m.applyFilter()
	if got := filteredIDs(m); len(got) != 3 {
		t.Fatalf("empty search = %v, want everything", got)
	}
}
