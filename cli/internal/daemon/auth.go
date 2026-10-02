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
	var result SignIns
	err := executeRead(ctx, conn, operation{Name: "sign in list", Method: http.MethodGet, Path: "/auth", Policy: readRecovery}, func(data []byte) error {
		var wire struct {
			Logins []struct {
				Provider *string `json:"provider"`
				Label    *string `json:"label"`
				Detail   *string `json:"detail"`
				Protocol *string `json:"protocol"`
			} `json:"logins"`
			Accounts []struct {
				Provider *string `json:"provider"`
				ID       *string `json:"id"`
				Label    *string `json:"label"`
				Detail   *string `json:"detail"`
				Selected *bool   `json:"selected"`
			} `json:"accounts"`
		}
		if err := json.Unmarshal(data, &wire); err != nil {
			return err
		}
		if wire.Logins == nil {
			return fieldError("logins")
		}
		if wire.Accounts == nil {
			return fieldError("accounts")
		}
		result = SignIns{Logins: make([]SignIn, 0, len(wire.Logins)), Accounts: make([]Account, 0, len(wire.Accounts))}
		for _, login := range wire.Logins {
			if login.Provider == nil {
				return fieldError("provider")
			}
			if login.Label == nil {
				return fieldError("label")
			}
			if login.Detail == nil {
				return fieldError("detail")
			}
			if login.Protocol == nil {
				return fieldError("protocol")
			}
			result.Logins = append(result.Logins, SignIn{Provider: *login.Provider, Label: *login.Label, Detail: *login.Detail, Protocol: *login.Protocol})
		}
		for _, account := range wire.Accounts {
			if account.Provider == nil {
				return fieldError("provider")
			}
			if account.ID == nil {
				return fieldError("id")
			}
			if account.Label == nil {
				return fieldError("label")
			}
			if account.Detail == nil {
				return fieldError("detail")
			}
			if account.Selected == nil {
				return fieldError("selected")
			}
			result.Accounts = append(result.Accounts, Account{Provider: *account.Provider, ID: *account.ID, Label: *account.Label, Detail: *account.Detail, Selected: *account.Selected})
		}
		return nil
	})
	return result, err
}

// StartSignIn begins a sign-in and returns the url the browser should open.
func StartSignIn(ctx context.Context, conn *Connection, provider string) (StartedSignIn, error) {
	var result StartedSignIn
	err := executeMutation(ctx, conn, operation{Name: "start sign in", Method: http.MethodPost, Path: "/auth/" + url.PathEscape(provider), Policy: authRecovery}, []int{http.StatusCreated}, func(data []byte, _ int) error {
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
	var result SignInStatus
	err := executeRead(ctx, conn, operation{Name: "poll sign in", Method: http.MethodGet, Path: "/auth/logins/" + url.PathEscape(id), Policy: readRecovery}, func(data []byte) error {
		var wire struct {
			State   *string `json:"state"`
			Message *string `json:"message"`
		}
		if err := json.Unmarshal(data, &wire); err != nil {
			return err
		}
		if wire.State == nil {
			return fieldError("state")
		}
		if wire.Message == nil {
			return fieldError("message")
		}
		switch *wire.State {
		case "waiting", "exchanging", "done", "failed":
		default:
			return fieldError("state")
		}
		result = SignInStatus{State: *wire.State, Message: *wire.Message}
		return nil
	})
	return result, err
}

// SignInInput delivers a pasted callback url, code#state, query string, or
// bare code; the daemon parses and races it against the browser callback.
func SignInInput(ctx context.Context, conn *Connection, id, input string) error {
	err := acknowledge(ctx, conn, operation{Name: "sign in input", Method: http.MethodPost, Path: "/auth/logins/" + url.PathEscape(id), Body: map[string]string{"input": input}, Policy: authRecovery})
	return err
}

func CancelSignIn(ctx context.Context, conn *Connection, id string) error {
	err := acknowledge(ctx, conn, operation{Name: "cancel sign in", Method: http.MethodDelete, Path: "/auth/logins/" + url.PathEscape(id), Body: nil, Policy: authRecovery})
	return err
}

func SelectAccount(ctx context.Context, conn *Connection, provider, id string) error {
	err := acknowledge(ctx, conn, operation{Name: "select account", Method: http.MethodPost, Path: accountPath(provider, id), Body: nil, Policy: authRecovery})
	return err
}

func RemoveAccount(ctx context.Context, conn *Connection, provider, id string) error {
	err := acknowledge(ctx, conn, operation{Name: "remove account", Method: http.MethodDelete, Path: accountPath(provider, id), Body: nil, Policy: authRecovery})
	return err
}
