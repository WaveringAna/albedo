package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"albedo/cli/internal/daemon/protocol"
)

type FolderList struct {
	Path      string        `json:"path"`
	Home      string        `json:"home"`
	Entries   []FolderEntry `json:"entries"`
	Truncated bool          `json:"truncated"`
}

type FolderEntry struct {
	Name string `json:"name"`
	// VCS is "jj", "git", or empty when the folder is no repository root.
	VCS      string `json:"vcs"`
	Modified int64  `json:"modified"` // Unix seconds; zero means unknown.
	Hidden   bool   `json:"hidden"`
}

// Repo is the repository a folder is in. Fields whose command failed are
// empty; Kind and Root are always there.
type Repo struct {
	Bookmark *Bookmark `json:"bookmark"`
	Changed  *int      `json:"changed"`
	Touched  *int64    `json:"touched"` // Unix seconds, when observed.
	Kind     string    `json:"kind"`
	Root     string    `json:"root"`
	Branch   string    `json:"branch"`
	Commit   string    `json:"commit"`
	Change   string    `json:"change"`
}

type Bookmark struct {
	Name  string `json:"name"`
	Ahead int    `json:"ahead"`
}

type FolderPreview struct {
	Path      string          `json:"path"`
	Repo      *Repo           `json:"repo"`
	Languages []LanguageShare `json:"languages"`
	Tree      []FolderNode    `json:"tree"`
	More      int             `json:"more"`
}

type LanguageShare struct {
	Name  string  `json:"name"`
	Color *string `json:"color"`
	Share float64 `json:"share"`
}

type FolderNode struct {
	Name     string       `json:"name"`
	Language string       `json:"language"`
	Children []FolderNode `json:"children"`
	Changed  int          `json:"changed"`
	More     int          `json:"more"`
	Dir      bool         `json:"dir"`
}

type HostStatus struct {
	Host        string `json:"host"`
	State       string `json:"state"`
	Detail      string `json:"detail"`
	Step        string `json:"step"`
	OS          string `json:"os"`
	Arch        string `json:"arch"`
	Home        string `json:"home"`
	ControlPath string `json:"control_path"`
}

// KnownHost is a host worth offering: one sessions worked on ("recent"), or
// a Host entry of the daemon's ssh config ("config"). State is the cached
// probe's, empty when there is none.
type KnownHost struct {
	Host   string `json:"host"`
	Label  string `json:"label"`
	Source string `json:"source"`
	State  string `json:"state"`
}

func workspaceDirectory(ctx context.Context, conn *Connection, location string, preview bool) (protocol.WorkspaceDirectory, error) {
	params := protocol.GetWorkspacesParams{Location: &location, Limit: new(int64(200))}
	if preview {
		params.Include = new("preview")
	}
	var result protocol.WorkspaceDirectory
	err := walkPages(func(next *string) (protocol.WorkspaceDirectory, *string, error) {
		params.Next = next
		var page protocol.WorkspaceDirectory
		pageErr := executeRead(ctx, conn, operation{Capability: "workspace_browsing", Name: "browse workspace", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
			return protocol.NewGetWorkspacesRequest(base, &params)
		}, Policy: readRecovery}, func(data []byte) error {
			return decodeRequired(data, &page)
		})
		return page, page.Next, pageErr
	}, func(page protocol.WorkspaceDirectory) error {
		if page.Items == nil {
			return fieldError("workspace entries")
		}
		if result.Directory == "" {
			result = page
		} else {
			if result.Directory != page.Directory {
				return fieldError("workspace page")
			}
			result.Items = append(result.Items, page.Items...)
		}
		return nil
	}, "workspace page cursor")
	if err != nil {
		return result, err
	}
	return result, nil
}

func ListFolders(ctx context.Context, conn *Connection, path string) (FolderList, error) {
	w, err := workspaceDirectory(ctx, conn, path, false)
	result := FolderList{Path: w.Directory, Home: value(w.Home), Entries: []FolderEntry{}}
	for _, row := range w.Items {
		var modified int64
		if t := timestampSeconds(value(row.ModifiedAt)); t != nil {
			modified = *t
		}
		result.Entries = append(result.Entries, FolderEntry{Name: row.Name, VCS: value(row.Vcs), Modified: modified, Hidden: row.Hidden})
	}
	return result, err
}
func previewValue(w protocol.WorkspacePreview, path string) (FolderPreview, error) {
	result := FolderPreview{Path: path, More: int(w.More), Languages: []LanguageShare{}, Tree: []FolderNode{}}
	if len(w.Repository) > 0 && string(w.Repository) != "null" {
		var kind struct {
			Kind string `json:"kind"`
		}
		if err := json.Unmarshal(w.Repository, &kind); err != nil {
			return result, err
		}
		switch kind.Kind {
		case "git":
			var r protocol.GitFacts
			if err := decodeRequired(w.Repository, &r); err != nil {
				return result, err
			}
			result.Repo = &Repo{Kind: r.Kind, Root: r.Root, Branch: value(r.Branch), Commit: value(r.Revision), Changed: intPointer(r.Changed), Touched: timestampSeconds(value(r.TouchedAt))}
		case "jj":
			var r protocol.JJFacts
			if err := decodeRequired(w.Repository, &r); err != nil {
				return result, err
			}
			result.Repo = &Repo{Kind: r.Kind, Root: r.Root, Change: value(r.ChangeID), Commit: value(r.Revision), Changed: intPointer(r.Changed), Touched: timestampSeconds(value(r.TouchedAt))}
			if r.Bookmark != nil {
				result.Repo.Bookmark = &Bookmark{Name: r.Bookmark.Name, Ahead: int(r.Bookmark.Ahead)}
			}
		default:
			return result, fieldError("repository kind")
		}
	}
	for _, row := range w.Languages {
		result.Languages = append(result.Languages, LanguageShare{Name: row.Name, Color: row.Color, Share: row.Share})
	}
	for _, row := range w.Tree {
		node := FolderNode{Name: row.Name, Language: value(row.Language), Dir: row.Kind == "directory", Changed: int(row.Changed), More: int(row.More)}
		for _, child := range row.Children {
			node.Children = append(node.Children, FolderNode{Name: child.Name, Dir: child.Kind == "directory", Language: value(child.Language), Changed: int(child.Changed)})
		}
		result.Tree = append(result.Tree, node)
	}
	return result, nil
}
func PreviewFolder(ctx context.Context, conn *Connection, path string) (FolderPreview, error) {
	w, err := workspaceDirectory(ctx, conn, path, true)
	if err != nil {
		return FolderPreview{}, err
	}
	if w.Preview == nil {
		return FolderPreview{}, fieldError("workspace preview")
	}
	return previewValue(*w.Preview, w.Directory)
}
func FolderRepo(ctx context.Context, conn *Connection, path string) (*Repo, error) {
	preview, err := PreviewFolder(ctx, conn, path)
	return preview.Repo, err
}
func MoveSession(ctx context.Context, conn *Connection, id, workspace string, condition SessionCondition) (Session, error) {
	return patchSession(ctx, conn, id, condition.ETag, map[string]any{"workspace": workspace, "family_revision": condition.FamilyRevision})
}
func hostValue(w protocol.Host) HostStatus {
	r := HostStatus{Host: w.Target, State: w.State, OS: value(w.Os), Arch: value(w.Architecture), Home: value(w.Home)}
	if w.Detail != nil {
		r.Detail = w.Detail.Detail
	}
	if w.Authentication != nil {
		r.ControlPath = value(w.Authentication.ControlPath)
	}
	return r
}
func hosts(ctx context.Context, conn *Connection) ([]protocol.Host, error) {
	result := []protocol.Host{}
	params := protocol.ListHostsParams{Limit: new(int64(200))}
	err := walkPages(func(next *string) (protocol.HostPage, *string, error) {
		params.Next = next
		var page protocol.HostPage
		pageErr := executeRead(ctx, conn, operation{Capability: "host_probes", Name: "list hosts", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
			return protocol.NewListHostsRequest(base, &params)
		}, Policy: readRecovery}, func(data []byte) error { return decodeRequired(data, &page) })
		return page, page.Next, pageErr
	}, func(page protocol.HostPage) error {
		result = append(result, page.Items...)
		return nil
	}, "host page cursor")
	if err != nil {
		return nil, err
	}
	return result, nil
}

func ListHosts(ctx context.Context, conn *Connection) ([]KnownHost, error) {
	rows, err := hosts(ctx, conn)
	result := []KnownHost{}
	for _, row := range rows {
		result = append(result, KnownHost{Host: row.Target, Label: row.Target, State: row.State})
	}
	return result, err
}
func GetHost(ctx context.Context, conn *Connection, host string) (HostStatus, error) {
	rows, err := hosts(ctx, conn)
	if err != nil {
		return HostStatus{}, err
	}
	for _, row := range rows {
		if row.Target == host {
			return hostValue(row), nil
		}
	}
	return HostStatus{Host: host, State: "unknown"}, nil
}
func WarmHost(ctx context.Context, conn *Connection, host string) (HostStatus, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	var w protocol.Host
	op := operation{Capability: "host_probes", Name: "probe host", BuildRequest: func(base string, body io.Reader) (*http.Request, error) {
		return protocol.NewProbeHostRequestWithBody(base, host, "application/json", body)
	}, Body: struct{}{}, Policy: noRecovery}
	body, err := requestBytes(ctx, conn, op, responseLimits{successStatus: http.StatusAccepted, bodyBytes: 1024 * 1024, errorBytes: 64 * 1024})
	if err != nil {
		return HostStatus{}, err
	}
	if err := decodeRequired(body, &w); err != nil {
		return HostStatus{}, invalidResponse(op, "", err)
	}
	if w.Target != host {
		return HostStatus{}, errors.New("host probe returned another host")
	}
	status := hostValue(w)
	for status.State == "probing" || status.State == "unknown" {
		timer := time.NewTimer(200 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return HostStatus{}, ctx.Err()
		case <-timer.C:
		}
		status, err = GetHost(ctx, conn, host)
		if err != nil {
			return HostStatus{}, err
		}
	}
	return status, nil
}
func (c *ChatClient) WarmHost(ctx context.Context, host string) (HostStatus, error) {
	return WarmHost(ctx, c.conn, host)
}
func (c *ChatClient) Host(ctx context.Context, host string) (HostStatus, error) {
	return GetHost(ctx, c.conn, host)
}
func (c *ChatClient) LocalDaemon() bool { return c.conn.Local() }
