package daemon

import (
	"albedo/cli/internal/config"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
)

type SignIn struct {
	Provider, Label, Detail, Protocol string
	Flows                             []string
	Fields                            []FormField
}
type Account struct {
	Provider, ID, Label, Detail string
	Selected                    bool
	SelectedByProfiles          []string
}
type SignIns struct {
	Logins   []SignIn
	Accounts []Account
}
type StartedSignIn struct{ ID, URL, ETag string }
type SignInStatus struct {
	State, Message, ETag, Instructions, URL, Provider string
	Accounts                                          []Account
}

func accountValue(w wireAccount) Account {
	return Account{Provider: w.Provider, ID: w.ID, Label: w.Label, Detail: w.Detail, Selected: len(w.SelectedByProfiles) > 0, SelectedByProfiles: w.SelectedByProfiles}
}
func SignInList(ctx context.Context, conn *Connection) (SignIns, error) {
	var result SignIns
	err := executeRead(ctx, conn, operation{Capability: "provider_auth", Name: "list provider accounts", Method: http.MethodGet, Path: "/auth", Policy: readRecovery}, func(data []byte) error {
		var w wireAuth
		if err := decodeRequired(data, &w, "providers", "accounts"); err != nil {
			return err
		}
		if w.Providers == nil || w.Accounts == nil {
			return fieldError("auth")
		}
		result = SignIns{Logins: []SignIn{}, Accounts: []Account{}}
		for _, p := range w.Providers {
			result.Logins = append(result.Logins, SignIn{Provider: p.ID, Label: p.Label, Detail: p.Detail, Flows: p.Flows, Fields: p.Fields})
		}
		for _, a := range w.Accounts {
			result.Accounts = append(result.Accounts, accountValue(a))
		}
		return nil
	})
	return result, err
}
func loginValue(w wireLogin, etag string) (SignInStatus, error) {
	if w.ID == "" || etag == "" || w.Accounts == nil {
		return SignInStatus{}, fieldError("login")
	}
	switch w.State {
	case "waiting", "exchanging", "complete", "failed", "cancelled", "expired":
	default:
		return SignInStatus{}, fieldError("login state")
	}
	if urlText := value(w.URL); urlText != "" {
		parsed, err := url.Parse(urlText)
		if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
			return SignInStatus{}, fieldError("login URL")
		}
	}
	r := SignInStatus{State: w.State, Message: w.Progress, ETag: etag, Instructions: value(w.Instructions), URL: value(w.URL), Provider: w.Provider, Accounts: []Account{}}
	if w.Failure != nil {
		r.Message = w.Failure.Detail
	}
	for _, a := range w.Accounts {
		r.Accounts = append(r.Accounts, accountValue(a))
	}
	return r, nil
}

// StartSignInWithID retains the same admitted intent when a transport failure is retried.
func StartSignInWithID(ctx context.Context, conn *Connection, id, provider, flow string, values map[string]json.RawMessage) (StartedSignIn, error) {
	result := StartedSignIn{ID: id}
	body := map[string]any{"provider": provider, "values": nonNilMap(values)}
	if flow != "" {
		body["flow"] = flow
	}
	frozen, err := json.Marshal(body)
	if err != nil {
		return result, err
	}
	op := operation{Capability: "provider_auth", Name: "start provider login", Method: http.MethodPut, Path: "/auth/logins/" + url.PathEscape(id), Body: json.RawMessage(frozen), Validator: &result.ETag, Policy: noRecovery}
	for attempt := range 2 {
		err = executeMutation(ctx, conn, op, []int{201, 200}, func(data []byte, _ int) error {
			var w wireLogin
			if err := decodeRequired(data, &w, "id", "provider", "url", "expires_at", "state", "instructions", "progress", "accounts", "failure"); err != nil {
				return err
			}
			if w.ID != id || w.Provider != provider {
				return fieldError("login identity")
			}
			status, err := loginValue(w, result.ETag)
			if err != nil {
				return err
			}
			result.URL = status.URL
			return nil
		})
		if err == nil {
			return result, nil
		}
		if _, uncertain := errors.AsType[*UncertainOutcomeError](err); !uncertain {
			return result, err
		}
		if ctx != nil && ctx.Err() != nil {
			return result, err
		}
		status, lookupErr := PollSignIn(ctx, conn, id)
		if lookupErr == nil {
			if status.Provider != provider {
				return result, fieldError("login provider")
			}
			result.URL, result.ETag = status.URL, status.ETag
			return result, nil
		}
		if api, ok := errors.AsType[*APIError](lookupErr); ok && api.StatusCode == 410 {
			return result, lookupErr
		}
		if attempt == 1 {
			return result, err
		}
	}
	panic("unreachable login retry budget")
}
func PollSignIn(ctx context.Context, conn *Connection, id string) (SignInStatus, error) {
	var result SignInStatus
	var etag string
	err := executeRead(ctx, conn, operation{Capability: "provider_auth", Name: "read provider login", Method: http.MethodGet, Path: "/auth/logins/" + url.PathEscape(id), Validator: &etag, Policy: readRecovery}, func(data []byte) error {
		var w wireLogin
		if err := decodeRequired(data, &w, "id", "provider", "url", "expires_at", "state", "instructions", "progress", "accounts", "failure"); err != nil {
			return err
		}
		if w.ID != id {
			return fieldError("login identity")
		}
		var err error
		result, err = loginValue(w, etag)
		return err
	})
	return result, err
}
func SignInInput(ctx context.Context, conn *Connection, id, input, etag string) error {
	headers, err := observedHeaders(etag)
	if err != nil {
		return err
	}
	var next string
	return executeMutation(ctx, conn, operation{Capability: "provider_auth", Name: "answer provider login", Method: http.MethodPatch, Path: "/auth/logins/" + url.PathEscape(id), Body: map[string]string{"response": input}, Headers: headers, Validator: &next, Policy: noRecovery}, []int{200}, func(data []byte, _ int) error {
		var w wireLogin
		if err := decodeRequired(data, &w, "id", "state", "accounts", "progress", "failure"); err != nil {
			return err
		}
		_, err := loginValue(w, next)
		return err
	})
}
func CancelSignIn(ctx context.Context, conn *Connection, id string) error {
	return executeMutation(ctx, conn, operation{Capability: "provider_auth", Name: "cancel provider login", Method: http.MethodDelete, Path: "/auth/logins/" + url.PathEscape(id), Policy: noRecovery}, []int{204}, func([]byte, int) error { return nil })
}
func SelectProfileAccount(ctx context.Context, conn *Connection, profile string, account Account, profiles config.Profiles) error {
	saved, ok := profiles.Providers[profile]
	if !ok || saved.Extension != account.Provider {
		return errors.New("select a profile for this account provider")
	}
	saved.AccountID = &account.ID
	return SaveProvider(ctx, conn, profile, saved, profiles.ETag)
}
func RemoveAccount(ctx context.Context, conn *Connection, id string) error {
	return executeMutation(ctx, conn, operation{Capability: "provider_auth", Name: "remove provider account", Method: http.MethodDelete, Path: "/auth/accounts/" + url.PathEscape(id), Policy: noRecovery}, []int{204}, func([]byte, int) error { return nil })
}

func StartProviderLogin(ctx context.Context, conn *Connection, provider, flow string, values map[string]json.RawMessage) (StartedSignIn, error) {
	id, err := operationID()
	if err != nil {
		return StartedSignIn{}, err
	}
	return StartSignInWithID(ctx, conn, id, provider, flow, values)
}
