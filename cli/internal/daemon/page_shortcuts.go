package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"

	"albedo/cli/internal/daemon/protocol"
)

// PreparedPageAction captures the descriptor and target observed before a shortcut runs.
type PreparedPageAction struct {
	Page    *PageDocument
	Request PageActionRequest
}

type pageShortcut struct {
	action, id, field, text string
}

func parsePageShortcut(command, text string) (pageShortcut, error) {
	verb, rest, _ := strings.Cut(strings.TrimSpace(text), " ")
	shortcut := pageShortcut{text: strings.TrimSpace(rest)}
	switch command {
	case "/work":
		switch verb {
		case "add":
			shortcut.action, shortcut.field = "create", "title"
		case "edit":
			shortcut.action, shortcut.field = "edit", "title"
		case "status":
			shortcut.action, shortcut.field = "edit", "status"
		case "remove":
			shortcut.action = "delete"
		}
	case "/paperclips":
		switch verb {
		case "acknowledge", "dismiss":
			shortcut.action = verb
		case "reply":
			shortcut.action, shortcut.field = "reply", "reply"
		case "resolve":
			shortcut.action, shortcut.field = "resolve", "resolution"
		case "remove":
			shortcut.action = "delete"
		}
	}
	if shortcut.action == "" {
		return shortcut, fmt.Errorf("unknown %s action %q", command, verb)
	}
	if shortcut.action != "create" {
		shortcut.id, shortcut.text, _ = strings.Cut(shortcut.text, " ")
		shortcut.text = strings.TrimSpace(shortcut.text)
		id, err := strconv.ParseInt(shortcut.id, 10, 64)
		if err != nil || id < 1 {
			return shortcut, errors.New("the action requires a positive item ID")
		}
		shortcut.id = strconv.FormatInt(id, 10)
	}
	if shortcut.field == "" && shortcut.text != "" {
		return shortcut, errors.New("this action takes only an item ID")
	}
	if shortcut.field != "" && shortcut.field != "resolution" && shortcut.text == "" {
		return shortcut, fmt.Errorf("%s requires %s", verb, shortcut.field)
	}
	return shortcut, nil
}

// PreparePageShortcut uses the page's own actions and captures off-page targets by ID.
func PreparePageShortcut(ctx context.Context, conn *Connection, session, command, text string) (*PreparedPageAction, error) {
	shortcut, err := parsePageShortcut(command, text)
	if err != nil {
		return nil, err
	}
	doc, err := LoadPage(ctx, conn, session, command)
	if err != nil {
		return nil, err
	}
	index := slices.IndexFunc(doc.Actions, func(action PageAction) bool { return action.ID == shortcut.action })
	if index < 0 {
		return nil, fmt.Errorf("%s does not offer the %s action", command, shortcut.action)
	}
	request := PageActionRequest{Action: doc.Actions[index], Session: doc.Session, Form: map[string]json.RawMessage{}}
	if shortcut.id != "" {
		row, err := shortcutRow(ctx, conn, doc.Session, command, shortcut.id)
		if err != nil {
			return nil, err
		}
		request.Row = &row
		index := slices.IndexFunc(doc.Rows, func(existing PageRow) bool { return existing.ID == row.ID })
		if index < 0 {
			doc.Rows = append(doc.Rows, row)
		} else {
			doc.Rows[index] = row
		}
	}
	if shortcut.field != "" && shortcut.text != "" {
		index := slices.IndexFunc(request.Action.Fields, func(field protocol.FormField) bool { return field.Name == shortcut.field })
		if index < 0 {
			return nil, fmt.Errorf("the action does not accept %s", shortcut.field)
		}
		parsed, err := ParseActionField(request.Action.Fields[index], shortcut.text)
		if err != nil {
			return nil, err
		}
		request.Form[shortcut.field] = parsed
	}
	return &PreparedPageAction{Page: doc, Request: request}, nil
}

func shortcutRow(ctx context.Context, conn *Connection, session *Session, command, id string) (PageRow, error) {
	var build func(string, io.Reader) (*http.Request, error)
	var route string
	if command == "/work" {
		build = func(base string, _ io.Reader) (*http.Request, error) {
			return protocol.NewGetWorkRequest(base, id, &protocol.GetWorkParams{Workspace: session.Workspace})
		}
		route = "/extensions/work/items/" + id + "?workspace=" + url.QueryEscape(session.Workspace)
	} else {
		build = func(base string, _ io.Reader) (*http.Request, error) {
			return protocol.NewGetPaperclipsRequest(base, id)
		}
		route = "/extensions/paperclips/items/" + id
	}
	var etag string
	data, err := requestBytes(ctx, conn, operation{Name: "read shortcut target", BuildRequest: build, Validator: &etag, Policy: readRecovery}, responseLimits{successStatus: http.StatusOK, bodyBytes: 1048576, errorBytes: 65536})
	if err != nil {
		return PageRow{}, err
	}
	if etag == "" {
		return PageRow{}, fieldError("shortcut target validator")
	}
	var title, detail, status string
	if command == "/work" {
		var item protocol.WorkItem
		if err := decodeRequired(data, &item); err != nil {
			return PageRow{}, err
		}
		if item.ID != id {
			return PageRow{}, fieldError("shortcut target identity")
		}
		title, detail, status = item.Title, item.Notes, item.Status
	} else {
		var item protocol.Paperclip
		if err := decodeRequired(data, &item); err != nil {
			return PageRow{}, err
		}
		if item.ID != id {
			return PageRow{}, fieldError("shortcut target identity")
		}
		title, detail, status = item.Title, item.Message, item.Status
		if title == "" {
			title = item.Message
		}
	}
	row := protocol.PageRow{ID: id, Text: title, Badge: &status, Detail: &detail, Tone: "plain"}
	row.Resource = &struct {
		ETag  protocol.ETag        `json:"etag"`
		URL   protocol.ResourceURL `json:"url"`
		Value protocol.DynamicJSON `json:"value"`
	}{etag, route, data}
	return pageRowValue(row), nil
}
