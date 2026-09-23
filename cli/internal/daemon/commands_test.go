package daemon

import (
	"testing"
)

func TestParseCommandCatalog(t *testing.T) {
	raw := []byte(`[
		{"name": "/help", "description": "show help", "method": "help", "arguments": [], "modelCallable": false, "userTurn": true},
		{"name": "/mode", "description": "switch mode", "method": "set_mode", "arguments": [
			{"name": "mode", "description": "target mode", "required": true, "choices": ["fast", "deep"]}
		], "modelCallable": true, "userTurn": true}
	]`)

	catalog, err := ParseCommandCatalog(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(catalog) != 2 {
		t.Fatalf("expected 2 commands, got %d", len(catalog))
	}

	menuItems := CommandMenuItems(catalog)
	if len(menuItems) != 3 { // /help, /mode fast, /mode deep
		t.Fatalf("expected 3 menu items, got %d", len(menuItems))
	}
	if menuItems[1].Name != "/mode fast" || menuItems[2].Name != "/mode deep" {
		t.Fatalf("unexpected menu items: %+v", menuItems)
	}

	name, args, ok := ParseCommandInvocation("/help", catalog)
	if !ok || name != "/help" || args != "" {
		t.Fatalf("unexpected invocation parse: %s, %s, %v", name, args, ok)
	}

	name, args, ok = ParseCommandInvocation("/mode deep please", catalog)
	if !ok || name != "/mode" || args != "deep please" {
		t.Fatalf("unexpected invocation parse: %s, %s, %v", name, args, ok)
	}
}
