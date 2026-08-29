# Security Policy

## Reporting a vulnerability

Please report vulnerabilities privately via GitHub's
**Security → Report a vulnerability** (private vulnerability reporting) on
this repository. Do not open a public issue for security reports.
You can expect an initial response within a week.

## Supported versions

Only the latest release receives fixes. Update with
`Update-AgentContinuity.ps1` (it refuses to run while a handoff session is
in progress).

## Security model (summary)

Agent Continuity moves code and (optionally) encrypted CLI session
snapshots between one person's machines through Git remotes. Its safety
rules, in order of importance:

- **Fail closed.** Any check that fails preserves the original state and
  stops: no force pushes, no automatic rebase/merge, no overwriting of
  session files, no partial handoffs. Concurrency safety rests on the
  fast-forward check of plain `git push` used as compare-and-swap for the
  lease (`locks/*`), sync (`sync/*`) and project refs.
- **Secrets never enter Git.** Every handoff commit is preceded by a
  secret scan (file-name and content rules; user rules are additive only
  and a broken rules file aborts the scan). Credential files (auth.json,
  tokens, private keys) are also blocked by profile boundaries
  (`allowedGlobs` / `excludedGlobs`).
- **Encryption at rest and in transit through the vault.** Backups, rescue
  bundles and session snapshots are `age` ciphertexts for registered
  recipients only. The machine identity key is protected with DPAPI on
  Windows (AES fallback elsewhere). Removing a recipient applies from the
  next backup onward — ciphertexts a lost machine already received cannot
  be recalled, so also revoke that machine's Git credentials.
- **Version honesty.** Every cross-machine record carries a
  `schemaVersion`; readers refuse records they do not understand instead
  of guessing.

### Known limitations

- Due to how the `age` CLI works, a decrypted identity file briefly exists
  in a locked temporary folder during decryption and is shredded
  immediately afterwards (documented exception; see the README security
  note).
- The release executable is not code-signed yet; Windows SmartScreen will
  warn on first run (distribution plan D5).
- Branch protection on the private vault's `locks/*` / `sync/*` refs is
  not applied on GitHub Free; the CAS property itself does not depend on
  it.
