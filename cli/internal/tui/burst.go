package tui

import (
	"cmp"
	"fmt"
	"path"
	"regexp"
	"slices"
	"strings"

	"albedo/cli/internal/daemon"
	"github.com/charmbracelet/x/ansi"
)

// A burst is the work between two pieces of prose: a run of compact entries,
// tool calls and thinking spells, drawn as one summary row. It renders once
// something else ends it; until then it is drawn live, so settled rows stay
// append-only.

// trailingBurst is the run of compact entries that ends entries.
func trailingBurst(entries []HistoryEntry, flags DisplayFlags) []HistoryEntry {
	i := len(entries)
	for i > 0 && Compact(entries[i-1], flags) {
		i--
	}
	return entries[i:]
}

// tally keeps labels in the order they first came, with how often each did.
type tally struct {
	keys   []string
	counts map[string]int
}

func (t *tally) add(key string) {
	if key == "" {
		return
	}
	if t.counts == nil {
		t.counts = map[string]int{}
	}
	if t.counts[key] == 0 {
		t.keys = append(t.keys, key)
	}
	t.counts[key]++
}

// dedup keeps first order and drops repeats naming produced.
func dedup(keys []string) []string {
	seen := make(map[string]bool, len(keys))
	kept := keys[:0:0]
	for _, key := range keys {
		if !seen[key] {
			seen[key] = true
			kept = append(kept, key)
		}
	}
	return kept
}

func (t *tally) addAll(keys []string) {
	for _, key := range keys {
		t.add(key)
	}
}

// counted labels each key, marking repeats: `go test ×4`.
func (t tally) counted() []string {
	labels := make([]string, len(t.keys))
	for i, key := range t.keys {
		labels[i] = key
		if n := t.counts[key]; n > 1 {
			labels[i] += fmt.Sprintf(" ×%d", n)
		}
	}
	return labels
}

// entryFacts is what one entry contributes to a burst, computed once when the
// entry settles. Targets stay as the trace recorded them; naming them for the
// workspace happens at render time, so a workspace change re-names old rows.
type entryFacts struct {
	thoughtMs int64
	untimed   bool
	read      []string
	edited    []string
	searched  []string
	ran       []string
	py        []string
	used      []string
	added     int
	removed   int
	changes   []daemon.FileChange
	failed    bool
}

// factsOf reads one entry's contribution, using what append already computed
// when it can.
func factsOf(entry HistoryEntry) entryFacts {
	if entry.facts != nil {
		return *entry.facts
	}
	var f entryFacts
	if entry.Kind == EntryThinking {
		f.thoughtMs, f.untimed = entry.ElapsedMs, entry.ElapsedMs <= 0
		return f
	}
	if entry.Kind != EntryTool {
		return f
	}
	f.failed = toolFailed(entry)
	if trace := entry.ToolTrace; trace != nil && (len(trace.Activities) > 0 || len(trace.Changes) > 0) {
		for _, change := range trace.Changes {
			f.edited = append(f.edited, prepareTarget(change.Path))
			f.added += change.Added
			f.removed += change.Removed
			f.changes = append(f.changes, change)
		}
		for _, activity := range trace.Activities {
			switch activity.Kind {
			case "read":
				f.read = append(f.read, activity.Target)
			case "list":
				f.read = append(f.read, strings.TrimSuffix(activity.Target, "/")+"/")
			case "search":
				f.searched = append(f.searched, oneLine(activity.Target))
			case "run":
				f.ran = append(f.ran, commandName(activity.Target))
			}
		}
		return f
	}
	arg := func(key string) string {
		s, _ := entry.ToolArgs[key].(string)
		return s
	}
	switch entry.ToolName {
	case "python":
		if label := pyLabel(arg("code")); label != "" {
			f.py = append(f.py, label)
		} else {
			f.py = append(f.py, "cell")
		}
	case "shell", "bash":
		f.ran = append(f.ran, cmp.Or(commandName(arg("command")), entry.ToolName))
	case "read_file":
		f.read = append(f.read, prepareTarget(arg("path")))
	case "write_file", "edit_file":
		f.edited = append(f.edited, prepareTarget(arg("path")))
	default:
		f.used = append(f.used, entry.ToolName)
	}
	return f
}

type burst struct {
	thoughts  int
	thoughtMs int64
	untimed   bool // a thought from before this client watched has no duration
	read      tally
	edited    tally
	searched  tally
	ran       tally
	py        tally
	used      tally
	added     int
	removed   int
	changes   []daemon.FileChange
	failed    []HistoryEntry
}

// merge folds one entry's facts into a burst.
func (b *burst) merge(f entryFacts, entry HistoryEntry) {
	if f.thoughtMs != 0 || f.untimed {
		b.thoughts++
		b.thoughtMs += f.thoughtMs
		b.untimed = b.untimed || f.untimed
	}
	b.read.addAll(f.read)
	b.edited.addAll(f.edited)
	b.searched.addAll(f.searched)
	b.ran.addAll(f.ran)
	b.py.addAll(f.py)
	b.used.addAll(f.used)
	b.added += f.added
	b.removed += f.removed
	b.changes = append(b.changes, f.changes...)
	if f.failed {
		b.failed = append(b.failed, entry)
	}
}

// collect merges every entry's facts; entries settled through the chat carry
// theirs already, so this only pays for tool results once per entry.
func collect(entries []HistoryEntry) burst {
	var b burst
	for _, entry := range entries {
		b.merge(factsOf(entry), entry)
	}
	return b
}

// pyLabel is what a python cell that ran nothing external was doing: the
// first line of it, folded and capped.
func pyLabel(code string) string {
	line := oneLine(firstLine(code))
	if len(line) > 48 {
		line = line[:45] + "…"
	}
	return line
}

// clause is a verb and what it acted on: n things, noun in the plural,
// listed as items. shown items fit, the rest count; none shown is a count.
type clause struct {
	verb, noun string
	n          int
	items      []string
	shown      int
}

func (c clause) String() string {
	if c.shown == 0 {
		noun := c.noun
		if c.n == 1 {
			noun = strings.TrimSuffix(noun, "s")
		}
		return fmt.Sprintf("%s %d %s", c.verb, c.n, noun)
	}
	text := c.verb + " " + strings.Join(c.items[:c.shown], ", ")
	if hidden := len(c.items) - c.shown; hidden > 0 {
		text += fmt.Sprintf(" +%d", hidden)
	}
	return text
}

// summary is the burst's one row: what it thought, read, changed, and ran,
// with the lists shortened until the row fits width.
func (r TranscriptRenderer) summary(b burst, width int, n namer) string {
	var head []string
	if b.thoughts > 0 {
		thought := "thought"
		if !b.untimed && b.thoughtMs >= 1000 {
			thought += " " + formatElapsed(b.thoughtMs)
		}
		head = append(head, thought)
	}
	// naming can make two recorded paths the same ("cli/a.go" and the absolute
	// form), so lists dedupe after naming, and reads defer to edits in that
	// same named space
	edited := dedup(n.all(b.edited.keys))
	editedSet := make(map[string]bool, len(edited))
	for _, p := range edited {
		editedSet[p] = true
	}
	var reads []string
	for _, p := range dedup(n.all(b.read.keys)) {
		if !editedSet[p] {
			reads = append(reads, p)
		}
	}
	var clauses []*clause
	for _, c := range []clause{
		{verb: "read", noun: "files", n: len(reads), items: pathGroups(reads)},
		{verb: "searched", noun: "patterns", n: len(b.searched.keys), items: dedup(n.all(b.searched.keys))},
		{verb: "edited", noun: "files", n: len(edited), items: pathGroups(edited)},
		{verb: "ran", noun: "commands", n: len(b.ran.keys), items: b.ran.counted()},
		{verb: "python", noun: "cells", n: len(b.py.keys), items: b.py.counted()},
		{verb: "used", noun: "tools", n: len(b.used.keys), items: b.used.counted()},
	} {
		if len(c.items) > 0 {
			c.shown = len(c.items)
			clauses = append(clauses, &c)
		}
	}
	line := func() string {
		parts := slices.Clone(head)
		for _, c := range clauses {
			parts = append(parts, c.String())
		}
		return strings.Join(parts, " · ")
	}
	tail := ""
	if n := len(b.failed); n > 0 {
		tail += r.Styles.Error.Render(fmt.Sprintf(" · %d failed", n))
	}
	if b.added+b.removed > 0 {
		tail += "  " + r.diffCounts(daemon.FileChange{Added: b.added, Removed: b.removed})
	}
	// shorten the longest list first; once each shows one item, the lists
	// become counts, what was read before what was edited
	room := width - ansi.StringWidth(tail)
	for ansi.StringWidth(line()) > room && shorten(clauses) {
	}
	return fit(r.Styles.Faint.Render(line()), tail, width)
}

// countedFirst ranks which list turns into a count first.
var countedFirst = map[string]int{"read": 0, "searched": 1, "used": 2, "ran": 3, "python": 4, "edited": 5}

// shorten hides one more item, and reports whether any was left to hide.
func shorten(clauses []*clause) bool {
	var pick *clause
	for _, c := range clauses {
		if c.shown > 1 && (pick == nil || c.shown > pick.shown) {
			pick = c
		}
	}
	if pick == nil {
		for _, c := range clauses {
			if c.shown == 1 && (pick == nil || countedFirst[c.verb] < countedFirst[pick.verb]) {
				pick = c
			}
		}
	}
	if pick == nil {
		return false
	}
	pick.shown--
	return true
}

// renderBurst is a burst's summary row, then the row of each call that
// failed, and with diffs shown, each change.
func (r TranscriptRenderer) renderBurst(b burst, flags DisplayFlags, width int) string {
	n := r.namer()
	rows := []string{markChrome + r.summary(b, width, n)}
	for _, entry := range b.failed {
		rows = append(rows, markChrome+r.Styles.Error.Render(toolRow(entry, true, "", width)))
	}
	if flags.Diffs {
		for _, change := range b.changes {
			if change.Kind == "diff" {
				rows = append(rows, r.renderDiffPath(change.Diff, change.Path, width))
			} else {
				rows = append(rows, r.Styles.Faint.Render(n.name(prepareTarget(change.Path))+": "+change.Reason))
			}
		}
	}
	return strings.Join(rows, "\n")
}

// pathGroups names paths by their parent and name, and paths that share a
// parent together: `tui/{chat,transcript}.go`.
func pathGroups(paths []string) []string {
	var dirs []string
	names := map[string][]string{}
	for _, p := range paths {
		dir, name := path.Split(strings.TrimSuffix(p, "/"))
		if strings.HasSuffix(p, "/") {
			name += "/"
		}
		if _, seen := names[dir]; !seen {
			dirs = append(dirs, dir)
		}
		names[dir] = append(names[dir], name)
	}
	labels := make([]string, len(dirs))
	parents := map[string]int{}
	for _, dir := range dirs {
		parents[parentName(dir)]++
	}
	for i, dir := range dirs {
		parent := parentName(dir)
		if parents[parent] > 1 {
			parent = dir // distinguish same-named folders in different subtrees
		}
		labels[i] = parent + braced(names[dir])
	}
	return labels
}

// parentName is the last directory of dir with its slash, or nothing at the root.
func parentName(dir string) string {
	if dir = strings.TrimSuffix(dir, "/"); dir == "" {
		return ""
	}
	if strings.HasPrefix(dir, "/") {
		return "/" + path.Base(dir) + "/"
	}
	return path.Base(dir) + "/"
}

// braced joins names in braces, a shared extension outside them.
func braced(names []string) string {
	if len(names) == 1 {
		return names[0]
	}
	ext := path.Ext(names[0])
	stems := make([]string, len(names))
	for i, name := range names {
		if ext == "" || path.Ext(name) != ext || strings.HasSuffix(name, "/") {
			return "{" + strings.Join(names, ",") + "}"
		}
		stems[i] = strings.TrimSuffix(name, ext)
	}
	return "{" + strings.Join(stems, ",") + "}" + ext
}

var (
	commandBreak = regexp.MustCompile(`&&|\|\||[;|\n]`)
	assignment   = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)
	subcommand   = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
	// setup that comes before the command a line is about
	preamble = wordSet("cd", "export", "set", "source", ".")
	// programs whose first word names what they do; for the rest it is data,
	// like grep's pattern
	subcommanded = wordSet("git", "jj", "go", "cargo", "gleam", "npm", "pnpm", "yarn", "bun", "uv",
		"pip", "nix", "brew", "docker", "kubectl", "systemctl", "tg", "gh", "make", "just")
)

func wordSet(names ...string) map[string]bool {
	m := make(map[string]bool, len(names))
	for _, name := range names {
		m[name] = true
	}
	return m
}

// commandName is what a command line runs, the program and its subcommand
// when it has one: `cd cli && go test ./...` ran `go test`.
func commandName(command string) string {
	for _, part := range commandBreak.Split(strings.ReplaceAll(command, "\\\n", ""), -1) {
		fields := strings.Fields(part)
		for len(fields) > 0 && (assignment.MatchString(fields[0]) || fields[0] == "exec" || fields[0] == "time") {
			fields = fields[1:]
		}
		if len(fields) == 0 || preamble[fields[0]] {
			continue
		}
		name := fields[0]
		if strings.HasPrefix(name, "/") {
			name = path.Base(name)
		}
		if len(fields) > 1 && subcommanded[name] && subcommand.MatchString(fields[1]) {
			name += " " + fields[1]
		}
		return name
	}
	return oneLine(command)
}

// thinkingLine follows the newest nonempty line, even when thinking arrives
// in fragments or ends in a newline; one-line summaries still show their header.
func thinkingLine(text string) string {
	for text != "" {
		at := strings.LastIndexByte(text, '\n')
		line := strings.TrimLeft(strings.TrimSpace(text[at+1:]), "#> ")
		if line = oneLine(strings.NewReplacer("**", "", "__", "").Replace(line)); line != "" {
			return line
		}
		if at < 0 {
			break
		}
		text = text[:at]
	}
	return ""
}
