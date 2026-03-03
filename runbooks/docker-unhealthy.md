# Docker Container Health Issues

**Alerts:** DockerContainerUnhealthy, DockerContainerRestarting, DockerContainerDown

## Symptoms

- Container health check is failing (status != healthy)
- Container is restarting repeatedly (>3 restarts in 15 minutes)
- Container has stopped running

**Impact:** Application or blockchain node services may be degraded or offline.

## Immediate Actions

### 1. Identify the affected container

```bash
docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.State}}"
```

### 2. Check container logs

```bash
docker logs --tail 100 <container_name>
docker logs --since 10m <container_name>
```

### 3. Check container health details

```bash
docker inspect --format='{{json .State.Health}}' <container_name> | jq .
```

### 4. Check system resources

```bash
docker stats --no-stream
df -h
free -h
```

## Deep Dive

### Container restart loop

```bash
# Check restart count and last exit code
docker inspect --format='{{.RestartCount}} restarts, exit code: {{.State.ExitCode}}' <container_name>

# Check OOM kills
dmesg | grep -i "oom\|killed" | tail -20

# Check resource limits
docker inspect --format='{{json .HostConfig.Memory}}' <container_name>
```

### Network issues

```bash
# Check container network
docker network inspect bridge
docker exec <container_name> ping -c 3 <target_host>
```

### Disk space issues

```bash
# Check Docker disk usage
docker system df
docker system df -v

# Prune unused resources if needed
# docker system prune -f
```

### Configuration issues

```bash
# Check environment variables
docker inspect --format='{{json .Config.Env}}' <container_name> | jq .

# Check mounted volumes
docker inspect --format='{{json .Mounts}}' <container_name> | jq .
```

## Remediation

### Restart the container

```bash
docker restart <container_name>
```

### Recreate with docker-compose

```bash
cd /path/to/compose
docker-compose up -d <service_name>
```

### Clear and rebuild

```bash
docker-compose down <service_name>
docker-compose up -d <service_name>
```

## Escalation

- If container continues to crash after restart: investigate application logs and recent changes
- If OOM killed: increase memory limits or investigate memory leak
- If disk full: expand storage or clean up unused images/volumes
- Escalate to the application team if root cause is application-level

## References

- [Dashboard: Infrastructure Overview](../dashboards/infra/infrastructure-overview.json)
- [Docker troubleshooting docs](https://docs.docker.com/config/containers/troubleshoot/)
