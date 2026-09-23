package main

// history is a bounded ring of one-line records. Positions are logical sequence
// numbers, not slice offsets, so eviction does not silently change an anchor.
type history struct {
	buf              []string
	first, next, top int
	follow           bool
	unseen           int
	expired          bool
}

func newHistory(capacity int) history {
	return history{buf: make([]string, max(1, capacity)), follow: true}
}
func (h *history) bottom(height int) int { return max(h.first, h.next-max(1, height)) }
func (h *history) append(line string, height int) {
	h.buf[h.next%len(h.buf)] = line
	h.next++
	if h.next-h.first > len(h.buf) {
		h.first = h.next - len(h.buf)
	}
	if h.follow {
		h.top = h.bottom(height)
		h.unseen = 0
		return
	}
	h.unseen++
	if h.top < h.first {
		h.top = h.first
		h.expired = true
	}
}
func (h *history) scroll(delta, height int) {
	h.top = min(max(h.first, h.top+delta), h.bottom(height))
	h.follow = h.top == h.bottom(height)
	if h.follow {
		h.unseen = 0
		h.expired = false
	}
}
func (h *history) latest(height int) {
	h.follow = true
	h.top = h.bottom(height)
	h.unseen = 0
	h.expired = false
}
func (h *history) resize(height int) {
	if h.follow {
		h.top = h.bottom(height)
	} else {
		h.top = min(max(h.first, h.top), h.bottom(height))
	}
}
func (h *history) visible(height int) []string {
	end := min(h.next, h.top+max(0, height))
	out := make([]string, 0, max(0, end-h.top))
	for i := h.top; i < end; i++ {
		out = append(out, h.buf[i%len(h.buf)])
	}
	return out
}
