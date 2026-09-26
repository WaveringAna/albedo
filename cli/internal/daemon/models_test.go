package daemon

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestModelListingAcceptsDetailsAndBareIDs(t *testing.T) {
	var got []Model
	body := `[{"id":"a","efforts":["low","high"],"context":200000,"output":null,"input":["text"]},"b"]`
	if err := json.Unmarshal([]byte(body), &got); err != nil {
		t.Fatal(err)
	}
	want := []Model{
		{ID: "a", Efforts: []string{"low", "high"}, Context: 200000, Input: []string{"text"}},
		{ID: "b"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}
