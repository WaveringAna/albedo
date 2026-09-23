// Package contracts is a dependency-free teaching fixture, not a UI framework.
// Its state is owned by one event loop; it is deliberately not thread-safe.
package contracts

type phase uint8

const (
	idle phase = iota
	debouncing
	loading
	ready
	failed
	stopped
)

type searchState struct {
	generation uint64
	query      string
	phase      phase
	rows       []string
	err        error
}

// change records new intent now, before the debounce timer fires. This fixture
// clears rows; an application may instead retain them with an explicit stale tag.
// The real application must also cancel its superseded backend context.
func (s *searchState) change(query string) uint64 {
	s.generation++
	s.query = query
	s.phase = debouncing
	s.rows = nil
	s.err = nil
	return s.generation
}

// begin admits one request for the current intent, rejecting stale or duplicate
// debounce messages. A same-query retry must first create new intent with change.
func (s *searchState) begin(generation uint64) bool {
	if generation != s.generation || s.phase != debouncing {
		return false
	}
	s.phase = loading
	return true
}

// finish transfers an immutable result to this state only while its request is
// active. The producer must not mutate rows concurrently, even during this copy.
func (s *searchState) finish(generation uint64, rows []string, err error) bool {
	if generation != s.generation || s.phase != loading {
		return false
	}
	if err != nil {
		s.phase = failed
		s.rows = nil
		s.err = err
		return true
	}
	s.phase = ready
	s.rows = append([]string(nil), rows...)
	s.err = nil
	return true
}

// stop invalidates pending completions. It does not stop real I/O; the caller
// must cancel and clean up the application's owned resources as well.
func (s *searchState) stop() {
	s.generation++
	s.phase = stopped
}

// bodyRows handles nonnegative row allocation. compact is true when the caller
// must use a different layout because the chrome does not fit. It does not
// measure text or model Lip Gloss's box behavior.
func bodyRows(total, header, footer int) (rows int, compact bool) {
	total = max(0, total)
	header = max(0, header)
	footer = max(0, footer)
	if header > total || footer > total-header {
		return 0, true
	}
	return total - header - footer, false
}
