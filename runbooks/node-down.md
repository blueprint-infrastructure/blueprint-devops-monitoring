# Node Down Runbook

## Symptoms

The `NodeDown` alert fires when a Prometheus target has been unreachable for more than 2 minutes. This indicates:
- The target endpoint is not responding to HTTP requests
- Network connectivity issues between Prometheus and the target
- The target service/process has crashed or is not running
- Firewall or security group blocking access

**Impact**: No metrics are being collected from this target, leading to blind spots in monitoring.

## Immediate Actions

### 1. Verify Alert Details
```bash
# Check Prometheus UI for alert details
# Review alert labels: instance, job, severity
# Check when the alert started firing
```

### 2. Check Target Accessibility
```bash
# Test HTTP connectivity to the target
curl -v http://<instance>:<port>/metrics

# Test basic network connectivity
ping <instance>
telnet <instance> <port>
```

### 3. Check Service Status
```bash
# SSH to the affected instance (if accessible)
ssh <instance>

# Check if the service is running
systemctl status <service-name>
# OR
docker ps | grep <container-name>
# OR
kubectl get pods -n <namespace> | grep <pod-name>
```

### 4. Restart Service (if safe)
```bash
# If service is down and restart is safe
systemctl restart <service-name>
# OR
docker restart <container-name>
# OR
kubectl restart deployment/<deployment-name> -n <namespace>
```

## Deep Dive

### 1. Check System Logs
```bash
# System logs
journalctl -u <service-name> -n 100 --no-pager
journalctl -xe | tail -50

# Application logs
tail -100 /var/log/<application>/app.log
docker logs <container-name> --tail 100
kubectl logs <pod-name> -n <namespace> --tail 100
```

### 2. Check System Resources
```bash
# Check if system is out of resources
free -h
df -h
top
iostat -x 1 5
```

### 3. Check Network Configuration
```bash
# Verify network interfaces
ip addr show
ifconfig

# Check firewall rules
iptables -L -n
# OR
firewall-cmd --list-all
```

### 4. Verify Prometheus Configuration
```bash
# Check if target is in Prometheus scrape config
# Review prometheus.yml or service discovery configuration
# Verify target URL, port, and path are correct
```

### 5. Check for Recent Changes
```bash
# Review recent deployments or configuration changes
# Check change logs or deployment history
# Review recent system updates
```

## Escalation

Escalate to senior engineers if:
- Service cannot be restarted after 15 minutes
- Multiple nodes are down simultaneously
- Root cause is unclear after initial investigation
- Data loss or corruption is suspected
- Production impact is severe

**Escalation Contacts:**
- On-call engineer: [placeholder]
- Engineering lead: [placeholder]
- Infrastructure team: [placeholder]

## References

- **Monitoring Dashboard**: `dashboards/infra/node-overview.json`
- **Related Alerts**: `TargetScrapeError`
- **Prometheus Target Status**: Prometheus UI → Status → Targets
- **Service Documentation**: [placeholder URL]
