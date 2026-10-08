package tui

import "sync/atomic"

// pageStatus is the state every screen shares: the terminal size, the load
// or save in flight, and the last error and notice. Every request carries
// the Generation it was started under; a reply under any other is stale.
type pageStatus struct {
	Error, Notice             string
	Width, Height, Generation int
	Loading, Saving           bool
}

// newPageStatus starts a screen's first request under a new generation.
func newPageStatus(loading bool) pageStatus {
	return pageStatus{Loading: loading, Generation: nextPageGeneration()}
}

// Commands outlive closed screens; unique generations reject their replies.
var pageGeneration atomic.Int64

func nextPageGeneration() int { return int(pageGeneration.Add(1)) }

func (p *pageStatus) SetSize(width, height int) { p.Width, p.Height = width, height }

// settle takes a reply for the request busy tracks: false when it is stale
// or failed, with the failure shown.
func (p *pageStatus) settle(gen int, err error, busy *bool) bool {
	if gen != p.Generation {
		return false
	}
	*busy = false
	if err != nil {
		p.Error = err.Error()
		return false
	}
	return true
}
