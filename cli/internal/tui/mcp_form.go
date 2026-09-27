package tui

import (
	"albedo/cli/internal/config"
	"cmp"
	"errors"
	"maps"
	"net/url"
	"path"
	"regexp"
	"slices"
	"strings"

	tea "charm.land/bubbletea/v2"
)

// mcpForm adds or edits one MCP server on a single screen. Nothing is written
// until the whole form is saved, so a server that needs credentials gets them
// before its first connection attempt.
type mcpForm struct {
	// Editing names the server being edited; empty for a new server.
	Editing   string
	Transport string // "http" or "stdio"
	// NameTouched stops the name following the URL or command once typed.
	NameTouched bool
	// Stored is what mcp-credentials.json already holds for this server.
	Stored config.MCPServerSecrets
	// Base keeps fields the form does not edit (enabled, tools, timeouts).
	Base config.MCPServer
	form
}

const (
	fieldTransport = "transport"
	fieldURL       = "url"
	fieldCommand   = "command"
	fieldName      = "name"
	fieldToken     = "token"
	fieldHeader    = "header"
	fieldValue     = "value"
	fieldEnv       = "env"
)

// mcpFieldLabels renames the fields whose key is not the words a person
// reads; the rest label themselves.
var mcpFieldLabels = map[string]string{
	fieldToken: "bearer token",
	fieldValue: "header value",
}

func newMCPForm(editing string, server config.MCPServer, stored config.MCPServerSecrets) *mcpForm {
	transport := pick(server.Type == "stdio", "stdio", "http")
	keys := []string{fieldURL, fieldCommand, fieldName, fieldToken, fieldHeader, fieldValue, fieldEnv}
	f := &mcpForm{Editing: editing, Transport: transport, Base: server, Stored: stored, form: newForm(keys, fieldToken, fieldValue, fieldEnv)}
	f.Inputs[fieldURL].SetValue(server.URL)
	f.Inputs[fieldCommand].SetValue(joinCommand(server.Command, server.Args))
	f.Inputs[fieldName].SetValue(editing)
	f.NameTouched = editing != ""
	if stored.BearerToken != "" {
		f.Inputs[fieldToken].Placeholder = "stored · blank keeps it · - removes it"
	}
	if len(stored.Headers) > 0 {
		f.Inputs[fieldHeader].Placeholder = strings.Join(sortedKeys(stored.Headers), ", ") + " stored · add or replace one"
	}
	f.Inputs[fieldEnv].Placeholder = "KEY=value KEY2=value (optional)"
	if len(stored.Env) > 0 {
		f.Inputs[fieldEnv].Placeholder = strings.Join(sortedKeys(stored.Env), ", ") + " stored · KEY=value adds or replaces"
	}
	f.Focus = 1 // the address: transport already defaults to http
	f.focus(f.current())
	return f
}

// fields lists the rows for the current transport, in order.
func (f *mcpForm) fields() []string {
	if f.Transport == "stdio" {
		return []string{fieldTransport, fieldCommand, fieldName, fieldEnv}
	}
	return []string{fieldTransport, fieldURL, fieldName, fieldToken, fieldHeader, fieldValue}
}

func (f *mcpForm) current() string {
	fields := f.fields()
	return fields[min(f.Focus, len(fields)-1)]
}

// update handles one key or paste; submit reports that the form should be saved.
func (f *mcpForm) update(msg tea.Msg) (submit bool, cmd tea.Cmd) {
	if submit, handled := f.key(msg, f.fields(), 0); handled {
		return submit, nil
	}
	if f.current() == fieldTransport {
		if key, ok := msg.(tea.KeyPressMsg); ok && f.Editing == "" {
			switch key.String() {
			case "left", "right", "space":
				if f.Transport == "http" {
					f.Transport = "stdio"
				} else {
					f.Transport = "http"
				}
				f.suggestName()
			}
		}
		return false, nil
	}
	if f.current() == fieldName && f.Editing != "" {
		return false, nil // renaming would orphan stored credentials
	}
	input := f.Inputs[f.current()]
	before := input.Value()
	next, cmd := input.Update(msg)
	*input = next
	if input.Value() != before {
		switch f.current() {
		case fieldName:
			f.NameTouched = true
		case fieldURL, fieldCommand:
			f.suggestName()
		}
	}
	return false, cmd
}

func (f *mcpForm) suggestName() {
	if f.NameTouched {
		return
	}
	name := ""
	if f.Transport == "http" {
		name = nameFromURL(f.Inputs[fieldURL].Value())
	} else if argv, err := splitCommand(f.Inputs[fieldCommand].Value()); err == nil {
		name = nameFromCommand(argv)
	}
	f.Inputs[fieldName].SetValue(name)
}

// mcpSubmission is a validated form: the server entry and its credentials.
type mcpSubmission struct {
	Name    string
	Server  config.MCPServer
	Secrets config.MCPServerSecrets
}

func (f *mcpForm) submission(existing []capabilityItem) (mcpSubmission, error) {
	name := f.value(fieldName)
	if !mcpName.MatchString(name) {
		return mcpSubmission{}, errors.New("name: use 1–64 letters, digits, _ or -")
	}
	if f.Editing == "" && slices.ContainsFunc(existing, func(item capabilityItem) bool { return item.ID == name && !item.Draft }) {
		return mcpSubmission{}, errors.New("name: a server called " + name + " already exists")
	}
	server := f.Base
	server.Type = f.Transport
	secrets := config.MCPServerSecrets{BearerToken: f.Stored.BearerToken, Headers: copyMap(f.Stored.Headers), Env: copyMap(f.Stored.Env)}
	if f.Transport == "http" {
		raw := f.value(fieldURL)
		parsed, err := url.Parse(raw)
		if raw == "" || err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
			return mcpSubmission{}, errors.New("url: enter an http:// or https:// address")
		}
		server.URL, server.Command, server.Args, server.CWD = raw, "", nil, ""
		if token := f.value(fieldToken); token == "-" {
			secrets.BearerToken = ""
		} else if token != "" {
			secrets.BearerToken = token
		}
		header, value := f.value(fieldHeader), f.value(fieldValue)
		switch {
		case header == "" && value == "":
		case !mcpHeaderName.MatchString(header):
			return mcpSubmission{}, errors.New("header: enter a valid HTTP header name")
		case value == "-":
			delete(secrets.Headers, header)
		case value == "":
			return mcpSubmission{}, errors.New("header value: enter a value, or - to remove " + header)
		default:
			if secrets.Headers == nil {
				secrets.Headers = map[string]string{}
			}
			secrets.Headers[header] = value
		}
		secrets.Env = nil
	} else {
		argv, err := splitCommand(f.Inputs[fieldCommand].Value())
		if err != nil || len(argv) == 0 {
			return mcpSubmission{}, errors.New("command: enter the command that starts the server")
		}
		server.Command, server.Args, server.URL = argv[0], argv[1:], ""
		entries, err := splitCommand(f.Inputs[fieldEnv].Value())
		if err != nil {
			return mcpSubmission{}, errors.New("env: " + err.Error())
		}
		for _, entry := range entries {
			key, value, ok := strings.Cut(entry, "=")
			if !ok || !mcpEnvName.MatchString(key) {
				return mcpSubmission{}, errors.New("env: use KEY=value entries separated by spaces")
			}
			if secrets.Env == nil {
				secrets.Env = map[string]string{}
			}
			if value == "-" {
				delete(secrets.Env, key)
			} else {
				secrets.Env[key] = value
			}
		}
		secrets.BearerToken, secrets.Headers = "", nil
	}
	return mcpSubmission{Name: name, Server: server, Secrets: secrets}, nil
}

func (f *mcpForm) view(width int) []string {
	f.fit(width - 16)
	rows := []string{DefaultStyles.Bold.Render(pick(f.Editing != "", "edit "+f.Editing, "add MCP server"))}
	for i, key := range f.fields() {
		value := f.Transport
		if key != fieldTransport {
			value = f.Inputs[key].View()
		} else if f.Editing == "" {
			value = pick(f.Transport == "http", "‹http› ", " http  ") + pick(f.Transport == "http", " stdio ", "‹stdio›")
		}
		label := cmp.Or(mcpFieldLabels[key], key)
		rows = append(rows, formRow(i == f.Focus, label, 13, value, width))
	}
	var own []hint
	note := ""
	switch f.current() {
	case fieldTransport:
		if f.Editing == "" {
			own = []hint{{"←→", "http or stdio"}}
		}
	case fieldToken:
		note = "optional · sent as Authorization: Bearer"
	case fieldHeader, fieldValue:
		note = "optional custom header, stored privately"
	case fieldEnv:
		note = "optional, stored privately"
	}
	return append(rows, "", formFooter(note, width, own...))
}

var nameUnsafe = regexp.MustCompile(`[^A-Za-z0-9_-]+`)

// nameFromURL suggests a server name from its host: mcp.linear.app → linear.
func nameFromURL(raw string) string {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Hostname() == "" {
		return ""
	}
	labels := strings.Split(parsed.Hostname(), ".")
	for len(labels) > 1 && (labels[0] == "mcp" || labels[0] == "api" || labels[0] == "www") {
		labels = labels[1:]
	}
	if len(labels) == 4 && strings.Trim(parsed.Hostname(), "0123456789.") == "" {
		return cleanName("mcp-" + strings.ReplaceAll(parsed.Hostname(), ".", "-"))
	}
	return cleanName(labels[0])
}

// nameFromCommand suggests a name from the package or program a command
// runs: npx -y @modelcontextprotocol/server-filesystem → filesystem.
func nameFromCommand(argv []string) string {
	if len(argv) == 0 {
		return ""
	}
	target := path.Base(argv[0])
	switch target {
	case "npx", "uvx", "bunx", "pnpx", "pipx", "node", "python", "python3", "uv", "docker":
		for _, arg := range argv[1:] {
			if !strings.HasPrefix(arg, "-") && arg != "run" && arg != "tool" {
				target = arg
				break
			}
		}
	}
	target = path.Base(target)
	if at := strings.LastIndex(target, "@"); at > 0 {
		target = target[:at]
	}
	for _, affix := range []string{"server-", "mcp-server-", "mcp-"} {
		target = strings.TrimPrefix(target, affix)
	}
	for _, affix := range []string{"-mcp-server", "-mcp", "-server"} {
		target = strings.TrimSuffix(target, affix)
	}
	return cleanName(target)
}

func cleanName(name string) string {
	name = strings.Trim(nameUnsafe.ReplaceAllString(strings.ToLower(name), "-"), "-_")
	if len(name) > 64 {
		name = name[:64]
	}
	return name
}

// splitCommand splits a command line on spaces, honouring single and double
// quotes and backslash escapes, without invoking a shell.
func splitCommand(line string) ([]string, error) {
	var args []string
	var current strings.Builder
	inArg, quote, escaped := false, rune(0), false
	for _, r := range line {
		switch {
		case escaped:
			current.WriteRune(r)
			escaped = false
		case r == '\\' && quote != '\'':
			escaped, inArg = true, true
		case quote != 0:
			if r == quote {
				quote = 0
			} else {
				current.WriteRune(r)
			}
		case r == '\'' || r == '"':
			quote, inArg = r, true
		case r == ' ' || r == '\t':
			if inArg {
				args = append(args, current.String())
				current.Reset()
				inArg = false
			}
		default:
			current.WriteRune(r)
			inArg = true
		}
	}
	if quote != 0 || escaped {
		return nil, errors.New("unterminated quote")
	}
	if inArg {
		args = append(args, current.String())
	}
	return args, nil
}

func joinCommand(command string, args []string) string {
	if command == "" {
		return ""
	}
	parts := []string{quoteArg(command)}
	for _, arg := range args {
		parts = append(parts, quoteArg(arg))
	}
	return strings.Join(parts, " ")
}

func quoteArg(arg string) string {
	if arg != "" && !strings.ContainsAny(arg, " \t'\"\\") {
		return arg
	}
	return "'" + strings.ReplaceAll(arg, "'", `'\''`) + "'"
}

func copyMap(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	return maps.Clone(in)
}

func sortedKeys(in map[string]string) []string {
	return slices.Sorted(maps.Keys(in))
}
