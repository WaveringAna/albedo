package tui

type Notice struct {
	Message string
	Error   bool
}

type Notices []Notice

func (ns *Notices) Add(msg string, isErr bool) bool {
	if msg == "" {
		return false
	}
	for _, n := range *ns {
		if n.Message == msg && n.Error == isErr {
			return false
		}
	}
	*ns = append(*ns, Notice{Message: msg, Error: isErr})
	return true
}

func (ns *Notices) AddNotice(msg string) bool {
	return ns.Add(msg, false)
}

func (ns *Notices) AddError(msg string) bool {
	return ns.Add(msg, true)
}

func (ns *Notices) Clear() {
	*ns = nil
}

func (ns Notices) HasError() bool {
	for _, n := range ns {
		if n.Error {
			return true
		}
	}
	return false
}

func (ns Notices) ChromeRows() int {
	if len(ns) == 0 {
		return 0
	}
	return len(ns) + 1
}
