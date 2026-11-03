# Launchd management upgrade

## Scope and acceptance

| Area | Required behavior | Evidence |
| --- | --- | --- |
| Lifecycle | Correct GUI/system targets; bootstrap, bootout, kickstart, TERM, restart; enable/disable overrides | Isolated real launchd job transitions |
| Delete/restore | Confirm impact; back up before unload/removal; preserve recovery metadata; restore without automatic execution | Real disposable job plus backup/restore checks |
| Process | PID/PPID/user/command/start/elapsed/CPU/memory; descendants; open files/network; signals with stale PID checks | Real disposable process and native window |
| Diagnostics | Raw launchctl print/blame, configuration validation, readable paths, errors and timestamps | Live read-only queries and malformed fixtures |
| Configuration/logs | Validate and back up writes; save/reload; correct descriptor ownership and rotation | Save/reload of disposable plist; rotation tests |
| Interface | Filters, bulk operations, runtime-only services, unified actions, errors, operation history, recovery sheet | Native UI interactions |

## Constraints

- Retain the previous security fixes.
- Use explicit launchd targets; service identity includes its domain.
- Never silently treat a failed query as an unloaded service.
- Protect Apple/system jobs from mutation in the service layer and interface.
- Admin actions use the macOS authorization prompt and quoted arguments.
- Deletion is recoverable and restore does not automatically run a job.
- Validate using only purpose-built disposable jobs; do not mutate existing user services.
- Local macOS build/install only; no public release or remote publication.

## Implementation and verification

## Delivered

- GUI and system inventories are queried separately; runtime-only registrations and malformed plists remain visible.
- Lifecycle uses bootstrap, bootout, kickstart and launchctl kill with explicit service targets.
- Enable/disable uses launchd overrides. Stop requests SIGTERM and explains KeepAlive relaunch behavior.
- Recoverable deletion verifies the registered plist path before unloading, so deleting a duplicate file does not stop a different registration.
- Recovery preserves original bytes, including malformed files, refuses overwrites, and never bootstraps automatically.
- Process inspector includes identity, owner, command, start/elapsed time, CPU/RSS/virtual memory, descendants, open files and network sockets.
- Signal delivery verifies the process identity and current launchd PID before sending it.
- Diagnostics includes configuration checks, launchctl state and run reason. Credential environment values are masked.
- Saving backs up the prior configuration and supports Save & Reload. System and Apple services remain protected.
- Creation supports user agents, global agents and global daemons with validation and an explicit destination review.
- Filters, bulk actions, domain-qualified pins, operation history, error feedback and menu bar controls use the same manager.
- Logs support pause/resume, bounded history, rotation and truncation with one owner per monitoring descriptor.

## Acceptance evidence

### Automated integration

The tests/run-management.sh runner compiles the actual services and runs purpose-built temporary jobs against macOS launchd. It also uses independent preferences and storage.

52 checks passed, covering actual lifecycle transitions, process suspension/resumption, stale PID rejection, system-domain discovery, duplicate and malformed files, deletion/recovery, changed program arguments after reload, domain-specific history, export collisions, directory-specific backups, file inspection, a real descendant process and a loopback listener, output larger than a pipe buffer, command timeout, log rotation and truncation.

The runner unloads its job and removes its temporary files on success and error. Logs: build/final-integration.log.

### Native interaction

Independent bundle com.acelogic.ignition.qa, agents under build/NativeQA/agents, storage under build/NativeQA/storage.

Verified:

- Select service → Start → list and detail update to Running with the new PID.
- Process Details → Overview, Children and Open Files show the actual test process.
- Diagnostics → checks and launchctl state; credential values display [redacted].
- Delete Service → impact/recovery explanation → Back Up and Delete → service disappears.
- Deleted Services → Restore → file returns and service remains Unloaded.
- Create wizard → fill label and paths → XML review → create without loading → new service appears.
- Recovery panel was visually inspected in the real native window.

The final installed app is version 1.1.0, build 2. Its executable SHA-256 is identical to the Release build; strict code signature verification passed. The app opens with the new inventory and controls.

### Platform limits

System-domain writes and lifecycle changes require the user's macOS administrator authorization. No administrator password was entered during this task; elevated mutations were not live-tested. Apple/system services are intentionally read only. Process file visibility is subject to macOS permissions.

## Local artifacts

- Release: build/Upgrade/Build/Products/Release/Ignition.app
- Installed: /Applications/Ignition.app
- Previous installed app retained at build/InstalledBackups/Ignition-1.0.app
- No public release or remote publication was performed.
