package daemon

import (
	"context"
	"net/url"
)

// The folder browser's routes, as robot-docs/workspaces.md describes them.

type FolderList struct {
	Path      string        `json:"path"`
	Home      string        `json:"home"`
	Truncated bool          `json:"truncated"`
	Entries   []FolderEntry `json:"entries"`
}

type FolderEntry struct {
	Name     string `json:"name"`
	Modified int64  `json:"modified"`
	Hidden   bool   `json:"hidden"`
	// VCS is "jj", "git", or empty when the folder is no repository root.
	VCS string `json:"vcs"`
}

// Repo is the repository a folder is in. Fields whose command failed are
// empty; Kind and Root are always there.
type Repo struct {
	Kind     string    `json:"kind"`
	Root     string    `json:"root"`
	Branch   string    `json:"branch"`
	Commit   string    `json:"commit"`
	Change   string    `json:"change"`
	Bookmark *Bookmark `json:"bookmark"`
	Changed  *int      `json:"changed"`
	Touched  *int64    `json:"touched"`
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
	Dir      bool         `json:"dir"`
	Language string       `json:"language"`
	Changed  int          `json:"changed"`
	More     int          `json:"more"`
	Children []FolderNode `json:"children"`
}

func ListFolders(ctx context.Context, conn *Connection, path string) (FolderList, error) {
	return Request[FolderList](ctx, conn, "/fs/list?path="+url.QueryEscape(path), nil)
}

func FolderRepo(ctx context.Context, conn *Connection, path string) (*Repo, error) {
	res, err := Request[struct {
		Repo *Repo `json:"repo"`
	}](ctx, conn, "/fs/repo?path="+url.QueryEscape(path), nil)
	return res.Repo, err
}

func PreviewFolder(ctx context.Context, conn *Connection, path string) (FolderPreview, error) {
	return Request[FolderPreview](ctx, conn, "/fs/preview?path="+url.QueryEscape(path), nil)
}

// MoveSession moves an idle session to another folder.
func MoveSession(ctx context.Context, conn *Connection, id, workspace string) (Session, error) {
	return Request[Session](ctx, conn, "/sessions/"+url.PathEscape(id)+"/workspace", map[string]string{"workspace": workspace})
}
