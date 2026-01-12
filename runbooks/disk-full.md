# Disk Full Runbook

## Symptoms

The `DiskSpaceLow` (warning) and `DiskSpaceCritical` (critical) alerts fire when disk usage exceeds thresholds:
- **Warning**: Disk usage > 85% for 10 minutes
- **Critical**: Disk usage > 95% for 5 minutes

**Impact**: 
- Application may fail to write logs or data
- System performance degradation
- Risk of complete disk fill leading to service failure
- Potential data loss if disk becomes 100% full

## Immediate Actions

### 1. Identify Affected Disk
```bash
# Check which mountpoint is affected
df -h

# Check specific mountpoint mentioned in alert
df -h <mountpoint>
```

### 2. Find Large Files and Directories
```bash
# Find largest directories
du -h --max-depth=1 <mountpoint> | sort -hr | head -20

# Find largest files
find <mountpoint> -type f -exec du -h {} + | sort -rh | head -20

# Find files larger than 1GB
find <mountpoint> -type f -size +1G -exec ls -lh {} \;
```

### 3. Check Common Problem Areas
```bash
# Log files
du -sh /var/log/*
journalctl --disk-usage

# Temporary files
du -sh /tmp/*
du -sh /var/tmp/*

# Docker (if applicable)
docker system df
du -sh /var/lib/docker/*

# Application data
du -sh /var/lib/<application>/*
```

### 4. Clean Up Safely (if identified)
```bash
# Rotate old logs
logrotate -f /etc/logrotate.conf

# Clean old journal logs (keep last 7 days)
journalctl --vacuum-time=7d

# Clean Docker (if applicable and safe)
docker system prune -a --volumes

# Remove old application logs (verify first!)
find /var/log/<application> -name "*.log.*" -mtime +30 -delete
```

## Deep Dive

### 1. Analyze Disk Usage Trends
```bash
# Check historical disk usage if monitoring available
# Review Grafana dashboard for disk usage trends
# Identify if this is a sudden spike or gradual growth
```

### 2. Check for Disk I/O Issues
```bash
# Monitor disk I/O
iostat -x 1 10

# Check for processes with high I/O
iotop

# Check disk health
smartctl -a /dev/<device>
```

### 3. Identify Root Cause
```bash
# Check for runaway processes writing logs
lsof | grep <mountpoint> | head -20

# Check for large core dumps
find <mountpoint> -name "core.*" -o -name "*.core"

# Check for orphaned files
# Review application-specific data growth patterns
```

### 4. Review Application Logging Configuration
```bash
# Check log rotation configuration
cat /etc/logrotate.d/<application>

# Review application log levels and output
# Consider reducing log verbosity if appropriate
```

### 5. Plan for Capacity
```bash
# Calculate growth rate
# Estimate time until disk is full
# Plan for disk expansion or data archival
```

## Escalation

Escalate to senior engineers if:
- Disk is > 98% full and cleanup is not possible
- Critical data may be lost
- Root cause is unclear (unexpected growth)
- Multiple disks are affected
- Disk expansion is required

**Escalation Contacts:**
- On-call engineer: [placeholder]
- Infrastructure team: [placeholder]
- Storage team: [placeholder]

## Prevention

- Set up log rotation with appropriate retention
- Monitor disk usage trends proactively
- Implement automated cleanup jobs for temporary files
- Plan for capacity based on growth trends
- Consider disk expansion before reaching 80% usage

## References

- **Monitoring Dashboard**: `dashboards/infra/node-overview.json`
- **Related Alerts**: `DiskSpaceLow`, `DiskSpaceCritical`
- **System Documentation**: [placeholder URL]
