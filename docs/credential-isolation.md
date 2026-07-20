# Credential isolation and scoped elevation

This document specifies the operational workflow for managing access to privileged
management-account roles, designed to minimize the window where a running agent or
stolen session could escalate.

## Threat model

The realistic risk is **concurrent sessions + credential availability**: being
logged into both a workload role and a management-admin role at once, where a
well-intended agent "runs away" with the management session. The daily driver
(`WorkloadAdmin`) is already SCP-bounded. The dangerous window is the rare
maintenance session where `LandingZoneAdmin` or `IdentityCenterAdmin` is active.

## Credential isolation

Agents must never be able to resolve to a management-admin profile. Enforce this
at the environment level:

### Option A: direnv (recommended for project directories)

Create a `.envrc` in every project directory where agents operate:

```bash
# .envrc — pins the agent to the workload profile
export AWS_PROFILE=paws-test-admin
```

This ensures any `aws` call or SDK credential resolution within that directory
uses only the workload profile, regardless of what other sessions exist.

### Option B: explicit profile pinning

When invoking an agent, always set the environment:

```bash
AWS_PROFILE=paws-test-admin <agent-command>
```

### Option C: separate OS user / container

Run agents as a distinct user whose `~/.aws/config` only contains workload
profiles. Management profiles are physically absent from the agent's view.

## Scoped elevation wrapper

For the rare maintenance windows, use a wrapper that automatically logs out when
done. Add this to your shell profile (e.g., `~/.zshrc`):

```bash
paws-admin() {
  local profile="${1:?Usage: paws-admin <profile> [command...]}"
  shift

  # Login
  aws sso login --profile "$profile" || return 1

  if [[ $# -gt 0 ]]; then
    # Run a single command, then logout
    AWS_PROFILE="$profile" "$@"
    aws sso logout --profile "$profile"
  else
    # Open a subshell; logout on exit
    (
      trap 'aws sso logout --profile '"$profile" EXIT
      export AWS_PROFILE="$profile"
      echo "Elevated shell: $profile (auto-logout on exit)"
      exec "$SHELL"
    )
  fi
}
```

Usage:

```bash
# Single command — auto-logout after
paws-admin paws-mgmt-landing ./scp-guardrails/deploy.sh

# Interactive subshell — auto-logout when you exit
paws-admin paws-mgmt-identity
```

## Periodic safety net (optional)

A macOS `launchd` agent that logs out all SSO sessions hourly, catching forgotten
sessions:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.paws.sso-logout</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/aws</string>
    <string>sso</string>
    <string>logout</string>
  </array>
  <key>StartInterval</key>
  <integer>3600</integer>
  <key>StandardOutPath</key>
  <string>/tmp/paws-sso-logout.log</string>
</dict>
</plist>
```

Install: `cp com.paws.sso-logout.plist ~/Library/LaunchAgents/ && launchctl load ~/Library/LaunchAgents/com.paws.sso-logout.plist`

## Day-to-day workflow

1. **Normal work:** use `paws-test-admin` or `paws-prod-admin` (WorkloadAdmin).
   Agents run here. SCP-bounded.
2. **Read-only investigation:** use `paws-mgmt-readonly` (ManagementReadOnly).
   Safe for agents too — no write permissions.
3. **Maintenance (rare):** use `paws-admin paws-mgmt-landing` or
   `paws-admin paws-mgmt-identity`. Never give this session to an agent.
   Auto-logout ensures the window closes.

## Controls summary

| Layer | Control | Protects against |
|-------|---------|-----------------|
| Environment | Profile isolation (direnv/pinning) | Agent reaching admin credentials |
| Time | 1h session duration on privileged sets | Stale credential reuse |
| Time | Scoped-elevation wrapper (auto-logout) | Forgotten active sessions |
| Time | Periodic launchd logout (optional) | Defense-in-depth for forgotten sessions |
| Policy | IdC Deny A (no assignment into management) | IdC-based escalation into management |
| Policy | IdC Deny B (no self-modification) | Removing Deny A |
| Policy | LandingZoneAdmin destructive-action deny | Accidental org destruction |
| Detection | Root-login + IdC-change + delegation alarms | Unknown escalation attempts |
