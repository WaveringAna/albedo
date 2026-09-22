import assert from "node:assert/strict"
import test from "node:test"
import { mkdtemp, readFile, rm, stat } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { codexAccounts, createAuthorization, credentialIdentity, parseAuthorizationInput, saveCodexAccount, type CodexCredential } from "./codex.js"

function access(accountId: string, accountUserId: string, email = "ana@example.test", marker = ""): string {
  return `header.${Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: accountId, chatgpt_account_user_id: accountUserId },
    "https://api.openai.com/profile": { email }, marker,
  })).toString("base64url")}.signature`
}
function credential(accountId: string, accountUserId: string, marker = ""): CodexCredential {
  return { type: "oauth", access: access(accountId, accountUserId, undefined, marker), refresh: `refresh-${accountUserId}-${marker}`,
    expires: Date.now() + 3_600_000, accountId, accountUserId, email: "ana@example.test" }
}

test("codex authorization matches the OpenAI CLI PKCE flow", () => {
  const auth = createAuthorization()
  const url = new URL(auth.url)
  assert.equal(url.origin + url.pathname, "https://auth.openai.com/oauth/authorize")
  assert.equal(url.searchParams.get("client_id"), "app_EMoamEEZ73f0CkXaXp7hrann")
  assert.equal(url.searchParams.get("redirect_uri"), "http://localhost:1455/auth/callback")
  assert.equal(url.searchParams.get("code_challenge_method"), "S256")
  assert.equal(url.searchParams.get("state"), auth.state)
  assert.equal(url.searchParams.get("id_token_add_organizations"), "true")
  assert.equal(url.searchParams.get("codex_cli_simplified_flow"), "true")
  assert.equal(url.searchParams.get("originator"), "albedo")
  assert.match(url.searchParams.get("scope") ?? "", /offline_access/)
  assert.match(url.searchParams.get("scope") ?? "", /api\.connectors\.invoke/)
  assert.equal(auth.verifier.length, 128)
  assert.equal(auth.state.length, 32)
})

test("manual authorization accepts callback urls, query strings, code-state pairs and raw codes", () => {
  assert.deepEqual(parseAuthorizationInput("http://localhost:1455/auth/callback?code=a&state=b"), { code: "a", state: "b" })
  assert.deepEqual(parseAuthorizationInput("code=a&state=b"), { code: "a", state: "b" })
  assert.deepEqual(parseAuthorizationInput("a#b"), { code: "a", state: "b" })
  assert.deepEqual(parseAuthorizationInput("a"), { code: "a" })
})

test("codex auth store appends accounts and refreshes one seat without replacing its sibling", async t => {
  const directory = await mkdtemp(join(tmpdir(), "albedo-codex-"))
  t.after(() => rm(directory, { recursive: true, force: true }))
  const first = credential("workspace", "seat-1")
  const second = credential("workspace", "seat-2")
  await saveCodexAccount(first, directory)
  await saveCodexAccount(second, directory)
  const refreshed = credential("workspace", "seat-1", "refreshed")
  await saveCodexAccount(refreshed, directory)
  const accounts = await codexAccounts(directory)
  assert.equal(accounts.length, 2)
  assert.deepEqual(accounts.map(credentialIdentity), ["account-user:seat-1", "account-user:seat-2"])
  assert.equal(accounts[0]!.access, refreshed.access)
  const saved = JSON.parse(await readFile(join(directory, "auth.json"), "utf8")) as Record<string, unknown>
  assert(Array.isArray(saved["openai-codex"]))
  assert.equal((await stat(directory)).mode & 0o777, 0o700)
  assert.equal((await stat(join(directory, "auth.json"))).mode & 0o777, 0o600)
})
