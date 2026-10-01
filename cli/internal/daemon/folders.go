package daemon

import (
	"context"
	"net/http"
	"net/url"
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
	return RequestOperation[FolderList](ctx, conn, Operation{Name: "list folders", Method: http.MethodGet, Path: "/fs/list?path=" + url.QueryEscape(path), Policy: ReadRecovery})
}

func FolderRepo(ctx context.Context, conn *Connection, path string) (*Repo, error) {
	res, err := RequestOperation[struct {
		Repo *Repo `json:"repo"`
	}](ctx, conn, Operation{Name: "read repository", Method: http.MethodGet, Path: "/fs/repo?path=" + url.QueryEscape(path), Policy: ReadRecovery})
	return res.Repo, err
}

func PreviewFolder(ctx context.Context, conn *Connection, path string) (FolderPreview, error) {
	return RequestOperation[FolderPreview](ctx, conn, Operation{Name: "preview folder", Method: http.MethodGet, Path: "/fs/preview?path=" + url.QueryEscape(path), Policy: ReadRecovery})
}

// MoveSession moves an idle session to another folder.
func MoveSession(ctx context.Context, conn *Connection, id, workspace string) (Session, error) {
	return RequestOperation[Session](ctx, conn, Operation{Name: "move session", Method: http.MethodPost, Path: "/sessions/" + url.PathEscape(id) + "/workspace", Body: map[string]string{"workspace": workspace}, Policy: AuthRecovery})
}
