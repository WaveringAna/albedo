// A healthy daemon cannot emit missing envelopes or null collection entries.
// These named-operation tests prevent malformed reads from becoming empty UI state.
package daemon

import (
	"errors"
	"net/http"
	"testing"
)

func TestAuxiliaryReadsRejectMalformedResponses(t *testing.T) {
	for _, test := range []struct {
		name string
		body string
		read func(*Connection) error
	}{
		{"missing sign-in accounts", `{"logins":[]}`, func(conn *Connection) error {
			_, err := SignInList(t.Context(), conn)
			return err
		}},
		{"null sign-in", `{"logins":[null],"accounts":[]}`, func(conn *Connection) error {
			_, err := SignInList(t.Context(), conn)
			return err
		}},
		{"unknown sign-in state", `{"state":"unexpected","message":""}`, func(conn *Connection) error {
			_, err := PollSignIn(t.Context(), conn, "login")
			return err
		}},
		{"missing folder entries", `{"path":"/work","home":"/home","truncated":false}`, func(conn *Connection) error {
			_, err := ListFolders(t.Context(), conn, "/work")
			return err
		}},
		{"null folder", `{"path":"/work","home":"/home","truncated":false,"entries":[null]}`, func(conn *Connection) error {
			_, err := ListFolders(t.Context(), conn, "/work")
			return err
		}},
		{"missing repository", `{}`, func(conn *Connection) error {
			_, err := FolderRepo(t.Context(), conn, "/work")
			return err
		}},
		{"null preview node", `{"path":"/work","repo":null,"languages":[],"tree":[null],"more":0}`, func(conn *Connection) error {
			_, err := PreviewFolder(t.Context(), conn, "/work")
			return err
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			conn, _ := mutationConnection(test.body, http.StatusOK)
			var protocol *ProtocolError
			if err := test.read(conn); !errors.As(err, &protocol) {
				t.Fatalf("malformed read did not return a protocol error: %v", err)
			}
		})
	}
}

func TestFolderReadsPreserveNullableMetadata(t *testing.T) {
	conn, _ := mutationConnection(`{"repo":null}`, http.StatusOK)
	if repo, err := FolderRepo(t.Context(), conn, "/work"); err != nil || repo != nil {
		t.Fatalf("folder outside repository must remain usable: %+v, %v", repo, err)
	}
	conn, _ = mutationConnection(`{"path":"/work","home":"/home","truncated":false,"entries":[{"name":"plain","modified":0,"hidden":false,"vcs":null}]}`, http.StatusOK)
	if folders, err := ListFolders(t.Context(), conn, "/work"); err != nil || len(folders.Entries) != 1 || folders.Entries[0].VCS != "" {
		t.Fatalf("plain folder lost nullable VCS: %+v, %v", folders, err)
	}
	conn, _ = mutationConnection(`{"path":"/work","repo":{"kind":"git","root":"/work","branch":null,"commit":null,"changed":null,"touched":null},"languages":[{"name":"Unknown","color":null,"share":1}],"tree":[{"name":"plain","dir":false,"changed":0,"language":null}],"more":0}`, http.StatusOK)
	if preview, err := PreviewFolder(t.Context(), conn, "/work"); err != nil || preview.Repo == nil || len(preview.Tree) != 1 || preview.Tree[0].Language != "" {
		t.Fatalf("valid preview with unavailable metadata failed: %+v, %v", preview, err)
	}
}

func TestSignInReadsPreserveAccountSelectionAndProgress(t *testing.T) {
	conn, _ := mutationConnection(`{"logins":[{"provider":"provider","label":"Sign in","detail":"Browser","protocol":"oauth"}],"accounts":[{"provider":"provider","id":"account","label":"Personal","detail":"Signed in","selected":false}]}`, http.StatusOK)
	got, err := SignInList(t.Context(), conn)
	if err != nil || len(got.Logins) != 1 || len(got.Accounts) != 1 {
		t.Fatalf("sign-in rows lost: %+v, %v", got, err)
	}
	login, account := got.Logins[0], got.Accounts[0]
	if login.Provider != "provider" || login.Label != "Sign in" || login.Detail != "Browser" || login.Protocol != "oauth" || account.Provider != "provider" || account.ID != "account" || account.Label != "Personal" || account.Detail != "Signed in" || account.Selected {
		t.Fatalf("sign-in fields lost: %+v", got)
	}
	conn, _ = mutationConnection(`{"state":"exchanging","message":"Finishing sign-in"}`, http.StatusOK)
	progress, err := PollSignIn(t.Context(), conn, "login")
	if err != nil || progress.State != "exchanging" || progress.Message != "Finishing sign-in" {
		t.Fatalf("sign-in progress lost: %+v, %v", progress, err)
	}
}
