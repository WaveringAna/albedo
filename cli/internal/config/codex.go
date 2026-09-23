package config

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	CodexClientID     = "app_EMoamEEZ73f0CkXaXp7hrann"
	CodexAuthorizeURL = "https://auth.openai.com/oauth/authorize"
	CodexTokenURL     = "https://auth.openai.com/oauth/token"
	CodexRedirectURI  = "http://localhost:1455/auth/callback"
	CodexScope        = "openid profile email offline_access api.connectors.read api.connectors.invoke"
	CodexAuthClaim    = "https://api.openai.com/auth"
	CodexProfileClaim = "https://api.openai.com/profile"
)

// CodexCredential holds OAuth credentials for OpenAI Codex.
type CodexCredential struct {
	Type          string  `json:"type"`
	Access        string  `json:"access"`
	Refresh       string  `json:"refresh"`
	Expires       int64   `json:"expires"`
	AccountID     string  `json:"accountId"`
	AccountUserID *string `json:"accountUserId,omitempty"`
	Email         *string `json:"email,omitempty"`
	// Selected marks the account the user chose in /login; the daemon tries it
	// before its per-session choice.
	Selected bool `json:"selected,omitempty"`
	// LimitedUntil is when a reported usage limit resets (unix ms); the daemon
	// skips the account until then while a sibling has usage.
	LimitedUntil int64 `json:"limitedUntil,omitempty"`
}

// CodexPlan returns the ChatGPT plan (plus, pro, team, ...) named in the
// credential's access token, or "" when it is not recorded.
func CodexPlan(cred CodexCredential) string {
	claims, err := parseJWT(cred.Access)
	if err != nil {
		return ""
	}
	plan, _ := asMap(claims["https://api.openai.com/auth"])["chatgpt_plan_type"].(string)
	return plan
}

// CredentialIdentity returns the canonical identity string for a credential.
func CredentialIdentity(cred CodexCredential) string {
	if cred.AccountUserID != nil && *cred.AccountUserID != "" {
		return "account-user:" + *cred.AccountUserID
	}
	if cred.AccountID != "" {
		return "account:" + cred.AccountID
	}
	if cred.Email != nil && *cred.Email != "" {
		return "email:" + strings.ToLower(*cred.Email)
	}
	h := sha256.Sum256([]byte(cred.Refresh))
	return "refresh:" + hex.EncodeToString(h[:])[:16]
}

func parseJWT(token string) (map[string]any, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, errors.New("invalid jwt")
	}
	seg := parts[1]
	if l := len(seg) % 4; l > 0 {
		seg += strings.Repeat("=", 4-l)
	}
	data, err := base64.URLEncoding.DecodeString(seg)
	if err != nil {
		return nil, err
	}
	var claims map[string]any
	if err := json.Unmarshal(data, &claims); err != nil {
		return nil, err
	}
	return claims, nil
}

func asMap(val any) map[string]any {
	if m, ok := val.(map[string]any); ok {
		return m
	}
	return nil
}

func extractTokenIdentity(access string, idToken *string) (accountID string, accountUserID, email *string, err error) {
	accessClaims, _ := parseJWT(access)
	var idClaims map[string]any
	if idToken != nil && *idToken != "" {
		idClaims, _ = parseJWT(*idToken)
	}

	auth := asMap(accessClaims[CodexAuthClaim])
	if auth == nil && idClaims != nil {
		auth = asMap(idClaims[CodexAuthClaim])
	}

	profile := asMap(accessClaims[CodexProfileClaim])
	if profile == nil && idClaims != nil {
		profile = asMap(idClaims[CodexProfileClaim])
	}

	if auth != nil {
		if rawID, ok := auth["chatgpt_account_id"].(string); ok && rawID != "" {
			accountID = rawID
		}
		if rawUID, ok := auth["chatgpt_account_user_id"].(string); ok && rawUID != "" {
			accountUserID = &rawUID
		}
	}
	if accountID == "" {
		return "", nil, nil, errors.New("codex token has no ChatGPT account id")
	}

	if profile != nil {
		if rawEmail, ok := profile["email"].(string); ok {
			trimmed := strings.ToLower(strings.TrimSpace(rawEmail))
			if trimmed != "" {
				email = &trimmed
			}
		}
	}

	return accountID, accountUserID, email, nil
}

// ParseAuthorizationInput extracts code and state from user input (URL or raw code).
func ParseAuthorizationInput(input string) (code, state string) {
	val := strings.TrimSpace(input)
	if val == "" {
		return "", ""
	}
	if u, err := url.Parse(val); err == nil && u.Scheme != "" && u.Host != "" {
		return u.Query().Get("code"), u.Query().Get("state")
	}
	if strings.Contains(val, "#") {
		parts := strings.SplitN(val, "#", 2)
		return parts[0], parts[1]
	}
	if strings.Contains(val, "code=") {
		values, err := url.ParseQuery(val)
		if err == nil {
			return values.Get("code"), values.Get("state")
		}
	}
	return val, ""
}

// CreateAuthorization generates PKCE parameters and authorization URL.
func CreateAuthorization() (verifier, state, urlStr string) {
	rawVerifier := make([]byte, 96)
	_, _ = rand.Read(rawVerifier)
	verifier = base64.RawURLEncoding.EncodeToString(rawVerifier)

	hash := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(hash[:])

	rawState := make([]byte, 16)
	_, _ = rand.Read(rawState)
	state = hex.EncodeToString(rawState)

	u, _ := url.Parse(CodexAuthorizeURL)
	q := u.Query()
	q.Set("response_type", "code")
	q.Set("client_id", CodexClientID)
	q.Set("redirect_uri", CodexRedirectURI)
	q.Set("scope", CodexScope)
	q.Set("code_challenge", challenge)
	q.Set("code_challenge_method", "S256")
	q.Set("state", state)
	q.Set("id_token_add_organizations", "true")
	q.Set("codex_cli_simplified_flow", "true")
	q.Set("originator", "albedo")
	u.RawQuery = q.Encode()

	return verifier, state, u.String()
}

// ExchangeCodexCode performs OAuth token exchange.
func ExchangeCodexCode(ctx context.Context, client *http.Client, code, verifier string) (*CodexCredential, error) {
	if client == nil {
		client = http.DefaultClient
	}

	form := url.Values{}
	form.Set("grant_type", "authorization_code")
	form.Set("client_id", CodexClientID)
	form.Set("code", code)
	form.Set("code_verifier", verifier)
	form.Set("redirect_uri", CodexRedirectURI)

	reqCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, CodexTokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	res, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()

	body, err := io.ReadAll(io.LimitReader(res.Body, 64*1024+1))
	if err != nil {
		return nil, err
	}
	if len(body) > 64*1024 {
		return nil, errors.New("codex token exchange response exceeded 64KB")
	}

	if res.StatusCode < 200 || res.StatusCode >= 300 {
		bodyStr := strings.TrimSpace(string(body))
		if bodyStr != "" {
			return nil, fmt.Errorf("codex token exchange failed (%d): %s", res.StatusCode, bodyStr)
		}
		return nil, fmt.Errorf("codex token exchange failed (%d)", res.StatusCode)
	}

	var resp struct {
		AccessToken  string  `json:"access_token"`
		RefreshToken string  `json:"refresh_token"`
		ExpiresIn    float64 `json:"expires_in"`
		IDToken      *string `json:"id_token"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, errors.New("codex token exchange response is incomplete")
	}

	if resp.AccessToken == "" || resp.RefreshToken == "" || resp.ExpiresIn <= 0 {
		return nil, errors.New("codex token exchange response is incomplete")
	}

	accountID, accountUserID, email, err := extractTokenIdentity(resp.AccessToken, resp.IDToken)
	if err != nil {
		return nil, err
	}

	nowMs := time.Now().UnixMilli()
	return &CodexCredential{
		Type:          "oauth",
		Access:        resp.AccessToken,
		Refresh:       resp.RefreshToken,
		Expires:       nowMs + int64(resp.ExpiresIn*1000),
		AccountID:     accountID,
		AccountUserID: accountUserID,
		Email:         email,
	}, nil
}

func readAuthData(directory string) (map[string]any, error) {
	authPath := filepath.Join(directory, "auth.json")
	fi, err := os.Stat(authPath)
	if err != nil {
		if os.IsNotExist(err) {
			return make(map[string]any), nil
		}
		return nil, errors.New("invalid credential store in auth.json; repair it before logging in")
	}
	if fi.Size() > 5*1024*1024 {
		return nil, errors.New("invalid credential store in auth.json; repair it before logging in")
	}
	data, err := os.ReadFile(authPath)
	if err != nil {
		if os.IsNotExist(err) {
			return make(map[string]any), nil
		}
		return nil, errors.New("invalid credential store in auth.json; repair it before logging in")
	}
	var res map[string]any
	if err := json.Unmarshal(data, &res); err != nil {
		return nil, errors.New("invalid credential store in auth.json; repair it before logging in")
	}
	return res, nil
}

func parseCredentialList(entry any) ([]CodexCredential, error) {
	if entry == nil {
		return []CodexCredential{}, nil
	}

	var items []any
	if slice, ok := entry.([]any); ok {
		items = slice
	} else {
		items = []any{entry}
	}

	results := make([]CodexCredential, 0, len(items))
	for _, item := range items {
		m, ok := item.(map[string]any)
		if !ok {
			return nil, errors.New("invalid openai-codex credentials in auth.json; repair them before logging in")
		}
		t, _ := m["type"].(string)
		access, _ := m["access"].(string)
		refresh, _ := m["refresh"].(string)
		accountID, _ := m["accountId"].(string)

		var expires int64
		switch v := m["expires"].(type) {
		case float64:
			expires = int64(v)
		case int64:
			expires = v
		default:
			return nil, errors.New("invalid openai-codex credentials in auth.json; repair them before logging in")
		}

		if t != "oauth" || access == "" || refresh == "" || accountID == "" || expires <= 0 {
			return nil, errors.New("invalid openai-codex credentials in auth.json; repair them before logging in")
		}

		var accountUserID *string
		if u, ok := m["accountUserId"].(string); ok && u != "" {
			accountUserID = &u
		}
		var email *string
		if em, ok := m["email"].(string); ok && em != "" {
			email = &em
		}

		selected, _ := m["selected"].(bool)
		var limitedUntil int64
		if v, ok := m["limitedUntil"].(float64); ok {
			limitedUntil = int64(v)
		}

		results = append(results, CodexCredential{
			Type:          t,
			Access:        access,
			Refresh:       refresh,
			Expires:       expires,
			AccountID:     accountID,
			AccountUserID: accountUserID,
			Email:         email,
			Selected:      selected,
			LimitedUntil:  limitedUntil,
		})
	}
	return results, nil
}

// LoadCodexAccounts reads and validates codex credentials from auth.json.
func LoadCodexAccounts(directory string) ([]CodexCredential, error) {
	data, err := readAuthData(directory)
	if err != nil {
		return nil, err
	}
	return parseCredentialList(data["openai-codex"])
}

// SaveCodexAccount saves or updates a codex credential in auth.json.
func SaveCodexAccount(directory string, cred CodexCredential) error {
	identity := CredentialIdentity(cred)
	return updateCodexAccounts(directory, func(accounts []CodexCredential) []CodexCredential {
		for i, acct := range accounts {
			if CredentialIdentity(acct) == identity {
				accounts[i] = cred
				return accounts
			}
		}
		return append(accounts, cred)
	})
}

// SelectCodexAccount makes the account with the given identity the one the
// daemon tries first, for new and running sessions alike.
func SelectCodexAccount(directory, identity string) error {
	return updateCodexAccounts(directory, func(accounts []CodexCredential) []CodexCredential {
		for i := range accounts {
			accounts[i].Selected = CredentialIdentity(accounts[i]) == identity
		}
		return accounts
	})
}

// RemoveCodexAccount drops the codex credential with the given identity from
// auth.json. Removing an account that is already gone is not an error.
func RemoveCodexAccount(directory, identity string) error {
	return updateCodexAccounts(directory, func(accounts []CodexCredential) []CodexCredential {
		kept := accounts[:0]
		for _, acct := range accounts {
			if CredentialIdentity(acct) != identity {
				kept = append(kept, acct)
			}
		}
		return kept
	})
}

// updateCodexAccounts rewrites the openai-codex entry under auth.lock.
func updateCodexAccounts(directory string, update func([]CodexCredential) []CodexCredential) error {
	return lockedUpdate(directory, "auth.lock", 100, func() error {
		data, err := readAuthData(directory)
		if err != nil {
			return err
		}
		accounts, err := parseCredentialList(data["openai-codex"])
		if err != nil {
			return err
		}
		accounts = update(accounts)
		switch len(accounts) {
		case 0:
			delete(data, "openai-codex")
		case 1:
			data["openai-codex"] = accounts[0]
		default:
			data["openai-codex"] = accounts
		}
		return writeJSONAtomic(directory, "auth.json", data)
	})
}

// OpenBrowser opens a URL in the system's default browser.
func OpenBrowser(urlStr string) {
	if flag.Lookup("test.v") != nil || os.Getenv("ALBEDO_NO_BROWSER") != "" {
		return
	}
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", urlStr)
	case "windows":
		cmd = exec.Command("cmd", "/c", "start", "", urlStr)
	default:
		cmd = exec.Command("xdg-open", urlStr)
	}
	_ = cmd.Start()
}

// StartCallbackServer starts the local OAuth redirect receiver on port 1455.
func StartCallbackServer(ctx context.Context, state string) (net.Listener, <-chan string, <-chan error, func()) {
	codeChan := make(chan string, 1)
	errChan := make(chan error, 1)

	mux := http.NewServeMux()
	server := &http.Server{
		Handler: mux,
	}

	listener, err := net.Listen("tcp", "127.0.0.1:1455")
	if err != nil {
		errChan <- err
		return nil, codeChan, errChan, func() {}
	}

	mux.HandleFunc("/auth/callback", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if r.URL.Path != "/auth/callback" {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte("callback route not found"))
			return
		}
		if r.URL.Query().Get("state") != state {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte("state mismatch"))
			return
		}
		code := r.URL.Query().Get("code")
		if code == "" {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte("missing authorization code"))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("OpenAI authentication completed. You can close this window."))
		select {
		case codeChan <- code:
		default:
		}
	})

	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			select {
			case errChan <- err:
			default:
			}
		}
	}()

	closeFn := func() {
		_ = server.Close()
		_ = listener.Close()
	}

	return listener, codeChan, errChan, closeFn
}

type CodexLoginOptions struct {
	OnAuth            func(url string)
	OnProgress        func(message string)
	OnManualCodeInput func() (string, error)
	OpenBrowser       bool
	HTTPClient        *http.Client
}

// LoginCodex orchestrates PKCE login flow.
func LoginCodex(ctx context.Context, opts CodexLoginOptions) (*CodexCredential, error) {
	verifier, state, authURL := CreateAuthorization()
	listener, codeChan, errChan, closeServer := StartCallbackServer(ctx, state)
	if listener == nil {
		return nil, <-errChan
	}
	defer closeServer()

	if opts.OnAuth != nil {
		opts.OnAuth(authURL)
	}
	if opts.OnProgress != nil {
		opts.OnProgress("waiting for browser authorization")
	}
	if opts.OpenBrowser {
		OpenBrowser(authURL)
	}

	manualChan := make(chan string, 1)
	manualErrChan := make(chan error, 1)
	if opts.OnManualCodeInput != nil {
		go func() {
			val, err := opts.OnManualCodeInput()
			if err != nil {
				manualErrChan <- err
				return
			}
			code, parsedState := ParseAuthorizationInput(val)
			if parsedState != "" && parsedState != state {
				manualErrChan <- errors.New("oauth state mismatch")
				return
			}
			if code == "" {
				manualErrChan <- errors.New("missing authorization code")
				return
			}
			manualChan <- code
		}()
	}

	var code string
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case err := <-errChan:
		return nil, err
	case code = <-codeChan:
	case code = <-manualChan:
	case err := <-manualErrChan:
		return nil, err
	}

	if opts.OnProgress != nil {
		opts.OnProgress("exchanging authorization code")
	}

	return ExchangeCodexCode(ctx, opts.HTTPClient, code, verifier)
}
