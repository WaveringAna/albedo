package config

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func makeAccessToken(accountID, accountUserID, email, marker string) string {
	payload := map[string]any{
		"https://api.openai.com/auth": map[string]any{
			"chatgpt_account_id":      accountID,
			"chatgpt_account_user_id": accountUserID,
		},
		"https://api.openai.com/profile": map[string]any{
			"email": email,
		},
		"marker": marker,
	}
	data, _ := json.Marshal(payload)
	b64 := base64.RawURLEncoding.EncodeToString(data)
	return fmt.Sprintf("header.%s.signature", b64)
}

func makeCredential(accountID, accountUserID, marker string) CodexCredential {
	email := "ana@example.test"
	uid := accountUserID
	return CodexCredential{
		Type:          "oauth",
		Access:        makeAccessToken(accountID, accountUserID, email, marker),
		Refresh:       fmt.Sprintf("refresh-%s-%s", accountUserID, marker),
		Expires:       time.Now().UnixMilli() + 3600000,
		AccountID:     accountID,
		AccountUserID: &uid,
		Email:         &email,
	}
}

func TestCodexAuthorizationParameters(t *testing.T) {
	verifier, state, authURL := CreateAuthorization()
	u, err := url.Parse(authURL)
	if err != nil {
		t.Fatal(err)
	}

	if u.Scheme+"://"+u.Host+u.Path != "https://auth.openai.com/oauth/authorize" {
		t.Fatalf("unexpected authorize URL: %s", authURL)
	}
	q := u.Query()
	if q.Get("client_id") != CodexClientID {
		t.Fatalf("unexpected client_id: %s", q.Get("client_id"))
	}
	if q.Get("redirect_uri") != CodexRedirectURI {
		t.Fatalf("unexpected redirect_uri: %s", q.Get("redirect_uri"))
	}
	if q.Get("code_challenge_method") != "S256" {
		t.Fatalf("unexpected code_challenge_method: %s", q.Get("code_challenge_method"))
	}
	if q.Get("state") != state {
		t.Fatalf("state mismatch in url: %s vs %s", q.Get("state"), state)
	}
	if q.Get("id_token_add_organizations") != "true" {
		t.Fatalf("unexpected id_token_add_organizations: %s", q.Get("id_token_add_organizations"))
	}
	if q.Get("codex_cli_simplified_flow") != "true" {
		t.Fatalf("unexpected codex_cli_simplified_flow: %s", q.Get("codex_cli_simplified_flow"))
	}
	if q.Get("originator") != "albedo" {
		t.Fatalf("unexpected originator: %s", q.Get("originator"))
	}
	if !strings.Contains(q.Get("scope"), "offline_access") || !strings.Contains(q.Get("scope"), "api.connectors.invoke") {
		t.Fatalf("unexpected scope: %s", q.Get("scope"))
	}

	if len(verifier) != 128 {
		t.Fatalf("expected verifier length 128, got %d", len(verifier))
	}
	if len(state) != 32 {
		t.Fatalf("expected state length 32, got %d", len(state))
	}
}

func TestParseAuthorizationInput(t *testing.T) {
	code, state := ParseAuthorizationInput("http://localhost:1455/auth/callback?code=foo&state=bar")
	if code != "foo" || state != "bar" {
		t.Fatalf("expected foo / bar, got: %s / %s", code, state)
	}

	code, state = ParseAuthorizationInput("foo#bar")
	if code != "foo" || state != "bar" {
		t.Fatalf("expected foo / bar, got: %s / %s", code, state)
	}

	code, state = ParseAuthorizationInput("code=baz&state=qux")
	if code != "baz" || state != "qux" {
		t.Fatalf("expected baz / qux, got: %s / %s", code, state)
	}

	code, state = ParseAuthorizationInput("just-a-code")
	if code != "just-a-code" || state != "" {
		t.Fatalf("expected just-a-code / empty, got: %s / %s", code, state)
	}
}

func TestCodexAccountsPersistence(t *testing.T) {
	tempDir, err := os.MkdirTemp("", "albedo-codex-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tempDir)

	accounts, err := LoadCodexAccounts(tempDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(accounts) != 0 {
		t.Fatalf("expected 0 accounts, got %d", len(accounts))
	}

	c1 := makeCredential("acct-1", "user-1", "v1")
	if err := SaveCodexAccount(tempDir, c1); err != nil {
		t.Fatal(err)
	}

	accounts, err = LoadCodexAccounts(tempDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(accounts) != 1 {
		t.Fatalf("expected 1 account, got %d", len(accounts))
	}
	if accounts[0].AccountID != "acct-1" {
		t.Fatalf("expected acct-1, got %s", accounts[0].AccountID)
	}

	// Update existing account (matching user identity)
	c1Updated := makeCredential("acct-1", "user-1", "v2")
	if err := SaveCodexAccount(tempDir, c1Updated); err != nil {
		t.Fatal(err)
	}
	accounts, err = LoadCodexAccounts(tempDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(accounts) != 1 {
		t.Fatalf("expected 1 account after update, got %d", len(accounts))
	}
	if accounts[0].Refresh != c1Updated.Refresh {
		t.Fatalf("expected updated refresh token %s, got %s", c1Updated.Refresh, accounts[0].Refresh)
	}

	// Add second account
	c2 := makeCredential("acct-2", "user-2", "v1")
	if err := SaveCodexAccount(tempDir, c2); err != nil {
		t.Fatal(err)
	}
	accounts, err = LoadCodexAccounts(tempDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(accounts) != 2 {
		t.Fatalf("expected 2 accounts, got %d", len(accounts))
	}

	// Check file permissions
	fileInfo, err := os.Stat(filepath.Join(tempDir, "auth.json"))
	if err != nil {
		t.Fatal(err)
	}
	if perm := fileInfo.Mode().Perm(); perm != 0600 {
		t.Fatalf("expected file mode 0600, got %o", perm)
	}
}

func TestRemoveCodexAccount(t *testing.T) {
	tempDir := t.TempDir()
	c1 := makeCredential("acct-1", "user-1", "v1")
	c2 := makeCredential("acct-2", "user-2", "v1")
	for _, c := range []CodexCredential{c1, c2} {
		if err := SaveCodexAccount(tempDir, c); err != nil {
			t.Fatal(err)
		}
	}

	if err := RemoveCodexAccount(tempDir, CredentialIdentity(c1)); err != nil {
		t.Fatal(err)
	}
	accounts, err := LoadCodexAccounts(tempDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(accounts) != 1 || accounts[0].AccountID != "acct-2" {
		t.Fatalf("expected only acct-2 to remain, got %+v", accounts)
	}

	if err := RemoveCodexAccount(tempDir, CredentialIdentity(c2)); err != nil {
		t.Fatal(err)
	}
	data, err := readAuthData(tempDir)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := data["openai-codex"]; ok {
		t.Fatal("removing the last account should drop the openai-codex key")
	}
	if err := RemoveCodexAccount(tempDir, CredentialIdentity(c2)); err != nil {
		t.Fatalf("removing a missing account should succeed, got %v", err)
	}
}
