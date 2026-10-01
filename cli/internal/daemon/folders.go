package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"time"
)

// The folder browser's routes, as robot-docs/workspaces.md describes them.

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
	Modified int64  `json:"modified"`
	Hidden   bool   `json:"hidden"`
}

// Repo is the repository a folder is in. Fields whose command failed are
// empty; Kind and Root are always there.
type Repo struct {
	Bookmark *Bookmark `json:"bookmark"`
	Changed  *int      `json:"changed"`
	Touched  *int64    `json:"touched"`
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
	Color string  `json:"color"`
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

func ListFolders(ctx context.Context, conn *Connection, path string) (FolderList, error) {
	var result FolderList
	err := executeRead(ctx, conn, operation{Name: "list folders", Method: http.MethodGet, Path: "/fs/list?path=" + url.QueryEscape(path), Policy: readRecovery}, func(data []byte) error {
		fields, err := object(data)
		if err != nil {
			return err
		}
		if err := required(fields, "path", &result.Path); err != nil {
			return err
		}
		if err := required(fields, "home", &result.Home); err != nil {
			return err
		}
		if err := required(fields, "truncated", &result.Truncated); err != nil {
			return err
		}
		var entries []json.RawMessage
		if err := required(fields, "entries", &entries); err != nil {
			return err
		}
		result.Entries = make([]FolderEntry, 0, len(entries))
		for _, raw := range entries {
			entry, err := object(raw)
			if err != nil {
				return err
			}
			var item FolderEntry
			if err := required(entry, "name", &item.Name); err != nil {
				return err
			}
			if err := required(entry, "modified", &item.Modified); err != nil {
				return err
			}
			if err := required(entry, "hidden", &item.Hidden); err != nil {
				return err
			}
			if err := nullable(entry, "vcs", &item.VCS); err != nil {
				return err
			}
			result.Entries = append(result.Entries, item)
		}
		return nil
	})
	return result, err
}

func FolderRepo(ctx context.Context, conn *Connection, path string) (*Repo, error) {
	var result *Repo
	err := executeRead(ctx, conn, operation{Name: "read repository", Method: http.MethodGet, Path: "/fs/repo?path=" + url.QueryEscape(path), Policy: readRecovery}, func(data []byte) error {
		fields, err := object(data)
		if err != nil {
			return err
		}
		result, err = decodeFolderRepo(fields)
		return err
	})
	return result, err
}

func PreviewFolder(ctx context.Context, conn *Connection, path string) (FolderPreview, error) {
	var result FolderPreview
	err := executeRead(ctx, conn, operation{Name: "preview folder", Method: http.MethodGet, Path: "/fs/preview?path=" + url.QueryEscape(path), Policy: readRecovery}, func(data []byte) error {
		fields, err := object(data)
		if err != nil {
			return err
		}
		if err := required(fields, "path", &result.Path); err != nil {
			return err
		}
		if err := required(fields, "more", &result.More); err != nil {
			return err
		}
		if result.More < 0 {
			return fieldError("more")
		}
		result.Repo, err = decodeFolderRepo(fields)
		if err != nil {
			return err
		}
		var languages, nodes []json.RawMessage
		if err := required(fields, "languages", &languages); err != nil {
			return err
		}
		result.Languages = make([]LanguageShare, 0, len(languages))
		for _, raw := range languages {
			language, err := object(raw)
			if err != nil {
				return err
			}
			var share LanguageShare
			if err := required(language, "name", &share.Name); err != nil {
				return err
			}
			if err := nullable(language, "color", &share.Color); err != nil {
				return err
			}
			if err := required(language, "share", &share.Share); err != nil {
				return err
			}
			if share.Share < 0 || share.Share > 1 {
				return fieldError("share")
			}
			result.Languages = append(result.Languages, share)
		}
		if err := required(fields, "tree", &nodes); err != nil {
			return err
		}
		result.Tree = make([]FolderNode, 0, len(nodes))
		for _, raw := range nodes {
			node, err := decodeFolderNode(raw)
			if err != nil {
				return err
			}
			result.Tree = append(result.Tree, node)
		}
		return nil
	})
	return result, err
}

func decodeFolderRepo(fields map[string]json.RawMessage) (*Repo, error) {
	var raw *json.RawMessage
	if err := nullable(fields, "repo", &raw); err != nil {
		return nil, err
	}
	if raw == nil {
		return nil, nil
	}
	fields, err := object(*raw)
	if err != nil {
		return nil, err
	}
	var repo Repo
	if err := required(fields, "kind", &repo.Kind); err != nil {
		return nil, err
	}
	if err := required(fields, "root", &repo.Root); err != nil {
		return nil, err
	}
	if err := nullable(fields, "changed", &repo.Changed); err != nil {
		return nil, err
	}
	if err := nullable(fields, "touched", &repo.Touched); err != nil {
		return nil, err
	}
	switch repo.Kind {
	case "git":
		if err := nullable(fields, "branch", &repo.Branch); err != nil {
			return nil, err
		}
		if err := nullable(fields, "commit", &repo.Commit); err != nil {
			return nil, err
		}
	case "jj":
		if err := nullable(fields, "change", &repo.Change); err != nil {
			return nil, err
		}
		var bookmark *json.RawMessage
		if err := nullable(fields, "bookmark", &bookmark); err != nil {
			return nil, err
		}
		if bookmark != nil {
			fields, err := object(*bookmark)
			if err != nil {
				return nil, err
			}
			repo.Bookmark = &Bookmark{}
			if err := required(fields, "name", &repo.Bookmark.Name); err != nil {
				return nil, err
			}
			if err := required(fields, "ahead", &repo.Bookmark.Ahead); err != nil {
				return nil, err
			}
		}
	default:
		return nil, fieldError("kind")
	}
	return &repo, nil
}

func decodeFolderNode(data []byte) (FolderNode, error) {
	var node FolderNode
	fields, err := object(data)
	if err != nil {
		return node, err
	}
	if err := required(fields, "name", &node.Name); err != nil {
		return node, err
	}
	if err := required(fields, "dir", &node.Dir); err != nil {
		return node, err
	}
	if err := required(fields, "changed", &node.Changed); err != nil {
		return node, err
	}
	if !node.Dir {
		if err := nullable(fields, "language", &node.Language); err != nil {
			return node, err
		}
	}
	// Only top-level directories include their immediate children and remainder.
	if _, present := fields["children"]; present {
		var children []json.RawMessage
		if err := required(fields, "children", &children); err != nil {
			return node, err
		}
		if err := required(fields, "more", &node.More); err != nil {
			return node, err
		}
		for _, raw := range children {
			child, err := decodeFolderNode(raw)
			if err != nil {
				return node, err
			}
			node.Children = append(node.Children, child)
		}
	}
	return node, nil
}

// MoveSession moves an idle session to another folder.
func MoveSession(ctx context.Context, conn *Connection, id, workspace string) (Session, error) {
	return mutateSession(ctx, conn, operation{Name: "move session", Method: http.MethodPost, Path: sessionPath(id, "/workspace"), Body: map[string]string{"workspace": workspace}, Policy: authRecovery}, http.StatusOK)
}

// HostStatus is what the daemon knows of a remote host over ssh: State is
// ready, warming, needs_auth, unreachable or unsupported; Detail says why
// when it is not ready. OS, Arch and Home come with a ready one.
type HostStatus struct {
	Host        string `json:"host"`
	State       string `json:"state"`
	Detail      string `json:"detail"`
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

// ListHosts is GET /hosts. It never probes.
func ListHosts(ctx context.Context, conn *Connection) ([]KnownHost, error) {
	var result []KnownHost
	err := executeRead(ctx, conn, operation{Name: "list hosts", Method: http.MethodGet, Path: "/hosts", Policy: readRecovery}, func(data []byte) error {
		fields, err := object(data)
		if err != nil {
			return err
		}
		return required(fields, "hosts", &result)
	})
	return result, err
}

// GetHost is the cached probe of host, or warming while one runs.
func GetHost(ctx context.Context, conn *Connection, host string) (HostStatus, error) {
	var status HostStatus
	err := executeRead(ctx, conn, operation{Name: "read host", Method: http.MethodGet, Path: "/hosts/" + url.PathEscape(host), Policy: readRecovery}, func(data []byte) error {
		return decodeHostStatus(data, &status)
	})
	return status, err
}

// WarmHost probes host now, past a cached answer, and answers how it went.
func WarmHost(ctx context.Context, conn *Connection, host string) (HostStatus, error) {
	// the probe waits up to a minute
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	var status HostStatus
	operation := operation{Name: "warm host", Method: http.MethodPost, Path: "/hosts/" + url.PathEscape(host) + "/warm", Body: map[string]any{}, Policy: authRecovery}
	// requestBytes directly: executeMutation would cap the wait at 20 s
	body, err := requestBytes(ctx, conn, operation, responseLimits{successStatus: http.StatusOK, bodyBytes: 64 * 1024, errorBytes: 64 * 1024})
	if err != nil {
		return status, err
	}
	if err := decodeHostStatus(body, &status); err != nil {
		return status, invalidResponse(operation, "", err)
	}
	return status, nil
}

// WarmHost probes the session's host again, past a cached failure, so a
// turn after a sign-in finds it ready.
func (c *ChatClient) WarmHost(ctx context.Context, host string) (HostStatus, error) {
	return WarmHost(ctx, c.conn, host)
}

// Host is the daemon's cached probe of host.
func (c *ChatClient) Host(ctx context.Context, host string) (HostStatus, error) {
	return GetHost(ctx, c.conn, host)
}

// LocalDaemon says the daemon runs on this machine, so an ssh master opened
// here is one it can ride.
func (c *ChatClient) LocalDaemon() bool {
	return c.conn.Local()
}

func decodeHostStatus(data []byte, status *HostStatus) error {
	fields, err := object(data)
	if err != nil {
		return err
	}
	if err := required(fields, "host", &status.Host); err != nil {
		return err
	}
	if err := required(fields, "state", &status.State); err != nil {
		return err
	}
	return json.Unmarshal(data, status)
}
