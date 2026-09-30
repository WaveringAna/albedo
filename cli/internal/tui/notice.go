package tui

import "slices"

type Notice struct {
	Message string
	Error   bool
}

type Notices []Notice

func (ns *Notices) Add(msg string, isErr bool) bool {
	if msg == "" || slices.Contains(*ns, Notice{msg, isErr}) {
		return false
	}
	*ns = append(*ns, Notice{Message: msg, Error: isErr})
	return true
}

func (ns *Notices) AddNotice(msg string) bool { return ns.Add(msg, false) }
func (ns *Notices) AddError(msg string) bool  { return ns.Add(msg, true) }
func (ns *Notices) Clear()                    { *ns = nil }

func (ns Notices) HasError() bool {
	return slices.ContainsFunc(ns, func(n Notice) bool { return n.Error })
}

func (ns Notices) ChromeRows() int {
	if len(ns) == 0 {
		return 0
	}
	return len(ns) + 1
}
