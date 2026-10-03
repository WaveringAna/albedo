package tui

import (
	"hash/fnv"
	"slices"
	"strings"
	"unicode/utf8"

	"albedo/cli/internal/daemon"
)

// node finds or makes the dot for a session.
func (m *AgentsViewModel) node(id, name string) *agentNode {
	if n, ok := m.nodes[id]; ok {
		if name != "" {
			n.name = name
		}
		return n
	}
	if name == "" {
		name = shortID(id)
	}
	n := &agentNode{id: id, name: name, hue: hueFor(id), phase: float64(hashOf(id)%628) / 100}
	m.nodes[id] = n
	return n
}

func shortID(id string) string {
	return id[:min(len(id), 8)]
}

func hashOf(s string) uint32 {
	h := fnv.New32a()
	_, _ = h.Write([]byte(s))
	return h.Sum32()
}

func hueFor(id string) rgb {
	hues := agentColors().hues
	return hues[hashOf(id)%uint32(len(hues))]
}

// apply folds one bus event into the view; true when the tree changed shape.
func (m *AgentsViewModel) apply(event daemon.AgentEvent) bool {
	kind := event.Type
	id := event.Session
	switch kind {
	case "spawn":
		parent := event.Parent
		if _, ok := m.nodes[parent]; !ok {
			return false
		}
		n := m.node(id, event.Name)
		n.parent, n.model, n.depth = parent, event.Model, event.Depth
		n.peer, n.flash = false, 1
		return true
	case "gone":
		if _, ok := m.nodes[id]; !ok {
			return false
		}
		delete(m.nodes, id)
		if m.rename.id == id {
			m.rename = renameField{}
		}
		if m.confirm == id {
			m.confirm = ""
		}
		if m.selected == id {
			m.selected = m.root
		}
		return true
	case "mail":
		if event.MailID != "" {
			if slices.Contains(m.seenMail, event.MailID) {
				return false
			}
			m.seenMail = capped(append(m.seenMail, event.MailID), 256)
		}
		from, to := event.From, event.To
		fromName := event.FromName
		changed := false
		ensure := func(nodeID, name string) {
			if _, ok := m.nodes[nodeID]; !ok {
				m.node(nodeID, name).peer = true
				changed = true
			}
		}
		ensure(to, "")
		source := agentsYou
		if from != "" {
			ensure(from, fromName)
			source = from
		}
		if changed {
			m.layout()
		}
		bytes, label := event.Bytes, event.Kind
		addMail := func(nodeID string, incoming bool, who string) {
			if n := m.nodes[nodeID]; n != nil {
				n.mail = capped(append(n.mail, agentMail{incoming: incoming, who: who, kind: label}), 12)
			}
		}
		addMail(to, true, m.label(source, fromName))
		addMail(source, false, m.label(to, ""))
		m.send(source, to, max(1, bytes/4))
		return false
	}
	n, ok := m.nodes[id]
	if !ok {
		return false
	}
	switch kind {
	case "activity":
		if event.Activity == nil {
			return false
		}
		if event.Cursor != nil && n.cursor != nil && event.Cursor.Generation == n.cursor.Generation && event.Cursor.Sequence <= n.cursor.Sequence {
			return false
		}
		n.currentRequest, n.latestProgress = "", ""
		if event.Activity.CurrentRequest != nil {
			n.currentRequest = event.Activity.CurrentRequest.Text
		}
		if event.Activity.LatestProgress != nil {
			n.latestProgress = *event.Activity.LatestProgress
		}
		n.cursor = event.Cursor
		n.running = event.Running
		if event.Status != nil {
			n.session.Status = *event.Status
		}
		delta := max(0, int(event.Activity.OutputScalars)-n.chars)
		n.rate += float64(delta)
		n.chars = int(event.Activity.OutputScalars)
		n.tail, n.preview = agentTail{}, agentTail{}
		n.lineKind = tailText
		n.progressByCallID = nil
		n.progressOrder = nil
		n.previewCallID = ""
		for _, line := range event.Activity.Lines {
			kind := tailText
			switch line.Kind {
			case "thinking":
				kind = tailThinking
			case "tool", "input", "note", "error":
				kind = tailMeta
			}
			n.tail.push(tailLine{kind: kind, text: line.Text})
		}
		for i := range event.CurrentProgress {
			progress := event.CurrentProgress[i]
			m.rememberProgress(n, &progress)
			if progress.Phase == "generating" {
				n.preview.setCode(progress.Code)
				n.previewCallID = progress.CallID
				n.lineKind = tailCode
			}
		}
		if input := event.Activity.LatestInput; input != nil && input.InputID != n.latestInput {
			if n.latestInput != "" && input.Source == "chat" {
				m.send(agentsYou, id, max(1, int(input.Bytes)/4))
			}
			n.latestInput = input.InputID
		}
		if answer := event.Activity.LatestAnswer; answer != nil && answer.MessageID != n.latestAnswer {
			if n.latestAnswer != "" && n.parent == "" && !n.peer {
				m.send(id, agentsYou, max(1, int(answer.Bytes)/4))
			}
			n.latestAnswer = answer.MessageID
		}
		n.revision++
	case "running":
		n.running = event.Running
		if !n.running {
			m.clearProgress(n)
		}
	case "text", "thinking":
		text := event.Text
		n.chars += utf8.RuneCountInString(text)
		n.rate += float64(len(text))
		tail := tailText
		if kind == "thinking" {
			tail = tailThinking
		}
		m.stream(n, tail, text)
	case "tool_progress":
		progress := event.Progress
		if progress == nil {
			m.clearProgress(n)
			break
		}
		m.rememberProgress(n, progress)
		if progress.Phase == "generating" {
			n.preview.setCode(progress.Code)
			n.previewCallID = progress.CallID
			n.lineKind = tailCode
			n.revision++
		} else {
			// A different call can still own the displayed code window. Hide it
			// without settling it into the tail; a later snapshot can restore it.
			if n.lineKind == tailCode {
				n.preview = agentTail{}
				n.previewCallID = ""
				n.lineKind = tailText
				n.revision++
			} else {
				m.flushLine(n)
			}
			m.pushTail(n, tailMeta, "▸ "+progress.Name)
		}
	case "tool":
		if n.lineKind != tailCode || n.previewCallID == event.ProgressCallID {
			m.flushLine(n)
		}
		m.removeProgress(n, event.ProgressCallID)
		for line := range strings.SplitSeq(event.Output, "\n") {
			if strings.TrimSpace(line) != "" {
				m.pushTail(n, tailOutput, line)
			}
		}
	case "user":
		text := event.Text
		m.flushLine(n)
		m.pushTail(n, tailMeta, "← "+firstLine(text))
		// Mail already travelled as a packet; a person typing is new.
		if event.Source == "chat" {
			m.send(agentsYou, id, max(1, len(text)/4))
		}
	case "message":
		// A root's answer goes back to you.
		if n.parent == "" && !n.peer {
			m.send(id, agentsYou, max(1, len(event.Text)/4))
		}
	case "error":
		m.clearProgress(n)
		n.running = false
		m.pushTail(n, tailMeta, "✕ "+event.Text)
	case "interrupted":
		m.clearProgress(n)
		n.running = false
		m.pushTail(n, tailMeta, "· interrupted")
	case "progress":
		m.flushLine(n)
		m.pushTail(n, tailMeta, "» "+event.Text)
		n.flash = 0.6
	case "renamed":
		n.name = event.Name
	case "closed":
		m.clearProgress(n)
		n.closed, n.running = true, false
	}
	return false
}

func (m *AgentsViewModel) clearProgress(node *agentNode) {
	m.flushLine(node)
	node.progressByCallID = nil
	node.progressOrder = nil
}

func (m *AgentsViewModel) rememberProgress(node *agentNode, progress *daemon.ToolProgress) {
	if node.progressByCallID == nil {
		node.progressByCallID = make(map[string]*daemon.ToolProgress)
	}
	if _, exists := node.progressByCallID[progress.CallID]; exists {
		node.progressOrder = slices.DeleteFunc(node.progressOrder, func(callID string) bool { return callID == progress.CallID })
	}
	node.progressByCallID[progress.CallID] = progress
	node.progressOrder = append(node.progressOrder, progress.CallID)
}

func (m *AgentsViewModel) removeProgress(node *agentNode, progressCallID string) {
	if progressCallID == "" || node.progressByCallID == nil {
		return
	}
	delete(node.progressByCallID, progressCallID)
	node.progressOrder = slices.DeleteFunc(node.progressOrder, func(callID string) bool { return callID == progressCallID })
	if len(node.progressOrder) == 0 {
		node.preview = agentTail{}
		node.previewCallID = ""
		node.lineKind = tailText
		node.revision++
		return
	}
	latest := node.progressByCallID[node.progressOrder[len(node.progressOrder)-1]]
	if latest.Phase == "generating" {
		node.preview.setCode(latest.Code)
		node.previewCallID = latest.CallID
		node.lineKind = tailCode
		node.revision++
	} else {
		node.preview = agentTail{}
		node.previewCallID = ""
		node.lineKind = tailText
		node.revision++
	}
}

// capped keeps only the newest keep entries of a growing slice.
func capped[S ~[]E, E any](list S, keep int) S {
	if len(list) > keep {
		return list[len(list)-keep:]
	}
	return list
}

// stream appends streamed text of one kind, closing a line at each newline.
func (m *AgentsViewModel) stream(n *agentNode, kind tailKind, text string) {
	if n.lineKind != kind {
		m.flushLine(n)
		n.lineKind = kind
	}
	for {
		head, rest, found := strings.Cut(text, "\n")
		n.preview.write(head, kind)
		n.revision++
		if !found {
			return
		}
		m.flushLine(n)
		n.lineKind = kind
		text = rest
	}
}

// flushLine settles whatever is streaming into the tail: a partial line, or
// the code of a finished tool call.
func (m *AgentsViewModel) flushLine(n *agentNode) {
	if n.lineKind == tailCode {
		lines := slices.Collect(n.preview.newest(true))
		for _, line := range slices.Backward(lines) {
			m.pushTail(n, tailCode, line.text)
		}
	} else {
		for line := range n.preview.newest(false) {
			if strings.TrimSpace(line.text) != "" {
				m.pushTail(n, n.lineKind, line.text)
			}
		}
	}
	n.tail.omitted = n.tail.omitted || n.preview.omitted
	n.preview = agentTail{}
	n.previewCallID = ""
	n.lineKind = tailText
	n.revision++
}

func (m *AgentsViewModel) pushTail(n *agentNode, kind tailKind, line string) {
	n.tail.push(tailLine{kind: kind, text: line})
	n.revision++
}
