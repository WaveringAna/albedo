package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
)

// Browser sign-ins run in the daemon so every client shares one OAuth
// implementation; these are the routes a client uses to list, start, poll,
// answer, and cancel one.

type SignIn struct {
	Provider string `json:"provider"`
	Label    string `json:"label"`
	Detail   string `json:"detail"`
	Protocol string `json:"protocol"`
}

type Account struct {
	Provider string `json:"provider"`
	ID       string `json:"id"`
	Label    string `json:"label"`
	Detail   string `json:"detail"`
	Selected bool   `json:"selected"`
}

// SignIns is everything /login can choose from: the sign-ins the enabled
// extensions offer and the accounts they have already stored.
type SignIns struct {
	Logins   []SignIn  `json:"logins"`
	Accounts []Account `json:"accounts"`
}

type StartedSignIn struct {
	ID  string `json:"id"`
	URL string `json:"url"`
}

type SignInStatus struct {
	State   string `json:"state"`
	Message string `json:"message"`
}

func accountPath(provider, id string) string {
	return "/auth/" + url.PathEscape(provider) + "/accounts/" + url.PathEscape(id)
}

func SignInList(ctx context.Context, conn *Connection) (SignIns, error) {
	return RequestOperation[SignIns](ctx, conn, Operation{Name: "sign in list", Method: http.MethodGet, Path: "/auth", Body: nil, Policy: ReadRecovery})
}

// StartSignIn begins a sign-in and returns the url the browser should open.
func StartSignIn(ctx context.Context, conn *Connection, provider string) (StartedSignIn, error) {
	var result StartedSignIn
	err := executeMutation(ctx, conn, Operation{Name: "start sign in", Method: http.MethodPost, Path: "/auth/" + url.PathEscape(provider), Policy: AuthRecovery}, []int{http.StatusCreated}, func(data []byte, _ int) error {
		var wire struct {
			ID  *string `json:"id"`
			URL *string `json:"url"`
		}
		if err := json.Unmarshal(data, &wire); err != nil {
			return err
		}
		if wire.ID == nil || strings.TrimSpace(*wire.ID) == "" {
			return fieldError("id")
		}
		if wire.URL == nil {
			return fieldError("url")
		}
		parsed, err := url.Parse(*wire.URL)
		if err != nil || !parsed.IsAbs() || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
			return fieldError("url")
		}
		result = StartedSignIn{ID: *wire.ID, URL: *wire.URL}
		return nil
	})
	return result, err
}

func PollSignIn(ctx context.Context, conn *Connection, id string) (SignInStatus, error) {
	return RequestOperation[SignInStatus](ctx, conn, Operation{Name: "poll sign in", Method: http.MethodGet, Path: "/auth/logins/" + url.PathEscape(id), Body: nil, Policy: ReadRecovery})
}

// SignInInput delivers a pasted callback url, code#state, query string, or
// bare code; the daemon parses and races it against the browser callback.
func SignInInput(ctx context.Context, conn *Connection, id, input string) error {
	err := acknowledge(ctx, conn, Operation{Name: "sign in input", Method: http.MethodPost, Path: "/auth/logins/" + url.PathEscape(id), Body: map[string]string{"input": input}, Policy: AuthRecovery})
	return err
}

func CancelSignIn(ctx context.Context, conn *Connection, id string) error {
	err := acknowledge(ctx, conn, Operation{Name: "cancel sign in", Method: http.MethodDelete, Path: "/auth/logins/" + url.PathEscape(id), Body: nil, Policy: AuthRecovery})
	return err
}

func SelectAccount(ctx context.Context, conn *Connection, provider, id string) error {
	err := acknowledge(ctx, conn, Operation{Name: "select account", Method: http.MethodPost, Path: accountPath(provider, id), Body: nil, Policy: AuthRecovery})
	return err
}

func RemoveAccount(ctx context.Context, conn *Connection, provider, id string) error {
	err := acknowledge(ctx, conn, Operation{Name: "remove account", Method: http.MethodDelete, Path: accountPath(provider, id), Body: nil, Policy: AuthRecovery})
	return err
}
