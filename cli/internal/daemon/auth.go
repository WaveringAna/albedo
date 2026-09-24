package daemon

import (
	"context"
	"errors"
	"net/http"
	"net/url"
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

type acknowledged struct {
	OK bool `json:"ok"`
}

func accountPath(provider, id string) string {
	return "/auth/" + url.PathEscape(provider) + "/accounts/" + url.PathEscape(id)
}

func SignInList(ctx context.Context, conn *Connection) (SignIns, error) {
	return authRequest[SignIns](ctx, conn, http.MethodGet, "/auth", nil)
}

// StartSignIn begins a sign-in and returns the url the browser should open.
func StartSignIn(ctx context.Context, conn *Connection, provider string) (StartedSignIn, error) {
	return authRequest[StartedSignIn](ctx, conn, http.MethodPost, "/auth/"+url.PathEscape(provider), nil)
}

func PollSignIn(ctx context.Context, conn *Connection, id string) (SignInStatus, error) {
	return authRequest[SignInStatus](ctx, conn, http.MethodGet, "/auth/logins/"+url.PathEscape(id), nil)
}

// SignInInput delivers a pasted callback url, code#state, query string, or
// bare code; the daemon parses and races it against the browser callback.
func SignInInput(ctx context.Context, conn *Connection, id, input string) error {
	_, err := authRequest[acknowledged](ctx, conn, http.MethodPost, "/auth/logins/"+url.PathEscape(id), map[string]string{"input": input})
	return err
}

func CancelSignIn(ctx context.Context, conn *Connection, id string) error {
	_, err := authRequest[acknowledged](ctx, conn, http.MethodDelete, "/auth/logins/"+url.PathEscape(id), nil)
	return err
}

func SelectAccount(ctx context.Context, conn *Connection, provider, id string) error {
	_, err := authRequest[acknowledged](ctx, conn, http.MethodPost, accountPath(provider, id), nil)
	return err
}

func RemoveAccount(ctx context.Context, conn *Connection, provider, id string) error {
	_, err := authRequest[acknowledged](ctx, conn, http.MethodDelete, accountPath(provider, id), nil)
	return err
}

func authRequest[T any](ctx context.Context, conn *Connection, method, path string, body any) (T, error) {
	var zero T
	if conn == nil {
		return zero, errors.New("daemon connection unavailable")
	}
	return RequestMethod[T](ctx, conn, method, path, body)
}
