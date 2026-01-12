# High CPU Runbook

## Symptoms

The `HighCPU` (warning) and `HighCPUCritical` (critical) alerts fire when CPU usage exceeds thresholds:
- **Warning**: CPU usage > 85% for 10 minutes
- **Critical**: CPU usage > 95% for 5 minutes

**Impact**:
- Application response time degradation
- Request timeouts and failures
- System instability
- Potential cascading failures

## Immediate Actions

### 1. Identify High CPU Processes
```bash
# Top processes by CPU
top -b -n 1 | head -20

# Alternative with more details
htop

# One-liner for top CPU consumers
ps aux --sort=-%cpu | head -10
```

### 2. Check System Load
```bash
# System load average
uptime
w

# Load average breakdown
cat /proc/loadavg
```

### 3. Check for Runaway Processes
```bash
# Find processes consuming excessive CPU
ps aux | awk '$3 > 80.0 {print $0}'

# Check for zombie processes
ps aux | grep -w Z
```

### 4. Quick Service Checks
```bash
# Check if application service is healthy
systemctl status <service-name>
curl http://localhost:<port>/health

# Check application metrics if available
# Review application-specific monitoring
```

## Deep Dive

### 1. Analyze CPU Usage by Core
```bash
# Per-core CPU usage
mpstat -P ALL 1 5

# CPU usage breakdown by mode
sar -u 1 10
```

### 2. Identify CPU-Intensive Operations
```bash
# Process tree with CPU usage
pstree -p | head -30

# Thread-level CPU usage (if applicable)
top -H -p <pid>

# Check for CPU throttling (containers)
# docker stats <container>
# kubectl top pod <pod-name>
```

### 3. Check System Resources
```bash
# Memory pressure can cause high CPU
free -h
vmstat 1 10

# I/O wait can appear as high CPU
iostat -x 1 10

# Check for swap usage
swapon --show
```

### 4. Application-Specific Investigation
```bash
# Check application logs for errors
tail -100 /var/log/<application>/app.log | grep -i error

# Check for infinite loops or recursive operations
# Review recent code deployments
# Check for configuration changes

# Application profiling (if tools available)
# - Java: jstack, jmap
# - Python: py-spy, cProfile
# - Node.js: clinic.js, 0x
```

### 5. Check for Resource Contention
```bash
# Check for CPU throttling (cgroups)
cat /sys/fs/cgroup/cpu/cpu.stat

# Check CPU frequency scaling
cpupower frequency-info

# Check for thermal throttling
sensors
```

### 6. Review Recent Changes
```bash
# Check recent deployments
# Review configuration changes
# Check for scheduled jobs (cron)
crontab -l
systemctl list-timers
```

## Remediation Steps

### 1. Restart Affected Service (if safe)
```bash
# Graceful restart
systemctl restart <service-name>
# OR
docker restart <container-name>
# OR
kubectl rollout restart deployment/<deployment-name>
```

### 2. Scale Horizontally (if applicable)
```bash
# Scale out application instances
# Add more replicas to handle load
kubectl scale deployment/<deployment-name> --replicas=<n>
```

### 3. Kill Runaway Process (last resort)
```bash
# Identify PID from top/htop
# Send SIGTERM first
kill <pid>

# If unresponsive, SIGKILL (use with caution)
kill -9 <pid>
```

### 4. Reduce Load (if possible)
```bash
# Temporarily disable non-critical jobs
# Rate limit incoming requests
# Enable maintenance mode if applicable
```

## Escalation

Escalate to senior engineers if:
- CPU remains > 95% after 30 minutes of investigation
- Multiple instances are affected
- Root cause is unclear
- Application is experiencing outages
- Scaling or infrastructure changes are required

**Escalation Contacts:**
- On-call engineer: [placeholder]
- Engineering lead: [placeholder]
- Infrastructure team: [placeholder]

## Prevention

- Set up CPU usage alerts at lower thresholds (e.g., 70%) for proactive monitoring
- Implement auto-scaling based on CPU metrics
- Profile applications regularly to identify optimization opportunities
- Review and optimize resource-intensive operations
- Consider vertical scaling if consistently high CPU

## References

- **Monitoring Dashboard**: `dashboards/infra/node-overview.json`
- **Related Alerts**: `HighCPU`, `HighCPUCritical`, `MemoryPressure`
- **Application Documentation**: [placeholder URL]
