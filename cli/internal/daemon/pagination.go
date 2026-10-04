// Package daemon adapts protocol resources and streams for the native client.
package daemon

// Walk pages without hiding endpoint-specific validation or accumulation.
func walkPages[Page any](fetch func(*string) (Page, *string, error), consume func(Page) error, cursorField string) error {
	var cursor *string
	seen := map[string]bool{}
	for {
		page, next, err := fetch(cursor)
		if err != nil {
			return err
		}
		if err := consume(page); err != nil {
			return err
		}
		if next == nil {
			return nil
		}
		if seen[*next] {
			return fieldError(cursorField)
		}
		seen[*next] = true
		cursor = next
	}
}
