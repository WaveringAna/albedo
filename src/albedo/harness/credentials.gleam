//// Credential data recovery and its startup notification.

/// Moves secrets still kept in auth.json, mcp-credentials.json or config.json
/// into creds.json, the old files into backups/ with `stamp` in their names.
/// Returns the files it moved secrets from.
@external(erlang, "albedo_credentials", "migrate")
pub fn migrate(home: String, stamp: String) -> Result(List(String), String)

/// Every client can observe the filenames moved during this daemon's start.
@external(erlang, "albedo_credentials", "migrated")
pub fn migrated() -> List(String)
