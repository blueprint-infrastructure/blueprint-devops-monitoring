# Runbook Conventions

This directory contains operational runbooks for alert remediation. Each runbook provides step-by-step procedures for responding to specific alert conditions.

## Runbook Structure

Each runbook should follow this structure:

### 1. Symptoms
- Description of what the alert indicates
- Observable symptoms and impact
- Related metrics and thresholds

### 2. Immediate Actions
- Quick checks to verify the issue
- Immediate remediation steps if safe to perform
- Service restart procedures if applicable

### 3. Deep Dive
- Root cause analysis steps
- Log investigation commands
- System diagnostic commands
- Performance analysis

### 4. Escalation
- When to escalate to senior engineers
- Escalation criteria and contacts
- Handoff procedures

### 5. References
- Related documentation
- External resources
- Monitoring dashboards
- Related alerts

## Runbook Naming

Runbooks are named after the alert they address:
- `node-down.md` → `NodeDown` alert
- `disk-full.md` → `DiskSpaceLow` / `DiskSpaceCritical` alerts
- `high-cpu.md` → `HighCPU` / `HighCPUCritical` alerts

## Best Practices

- **Actionable**: Provide specific commands and steps, not just descriptions
- **Environment-agnostic**: Use placeholders for hostnames, paths, and environment-specific values
- **Safe**: Clearly mark destructive operations and require confirmation
- **Complete**: Cover common scenarios and edge cases
- **Maintained**: Update runbooks when infrastructure or procedures change

## Integration

Runbooks are referenced in alert annotations via `runbook_url`. Use GitHub blob URLs:

```
https://github.com/blueprint-infrastructure/blueprint-devops-monitoring/blob/main/runbooks/<runbook>.md
```

Example:
- `disk-full.md` → `https://github.com/blueprint-infrastructure/blueprint-devops-monitoring/blob/main/runbooks/disk-full.md`
