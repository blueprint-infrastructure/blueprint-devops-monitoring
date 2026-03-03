# Avalanche Rewarding Stake Issues

**Alerts:** AvalancheRewardingStakeLow, AvalancheRewardingStakeCritical, AvalancheNodeUnhealthy, AvalancheNotBootstrapped, AvalancheBlocksBehind, AvalancheBlocksSeverelyBehind, AvalancheSyncing, AvalancheLowPeers, AvalancheNoPeers, AvalancheVersionDrift

## Symptoms

- Rewarding stake percentage dropped below 97% (warning) or 95% (critical)
- Node health check failing
- C-Chain not bootstrapped or syncing for extended period
- Node falling behind network block height
- Low or no peer connections

**Impact:** Low rewarding stake means the validator may not earn staking rewards. Below 80% uptime, rewards are forfeit.

## Immediate Actions

### 1. Check node health

```bash
curl -s -X POST --data '{"jsonrpc":"2.0","id":1,"method":"health.health"}' \
  -H 'content-type:application/json;' http://localhost:9650/ext/health | jq .
```

### 2. Check bootstrapping status

```bash
# C-Chain
curl -s -X POST --data '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"C"}}' \
  -H 'content-type:application/json;' http://localhost:9650/ext/info | jq .

# P-Chain
curl -s -X POST --data '{"jsonrpc":"2.0","id":1,"method":"info.isBootstrapped","params":{"chain":"P"}}' \
  -H 'content-type:application/json;' http://localhost:9650/ext/info | jq .
```

### 3. Check uptime

```bash
curl -s -X POST --data '{"jsonrpc":"2.0","id":1,"method":"info.uptime"}' \
  -H 'content-type:application/json;' http://localhost:9650/ext/info | jq .
```

### 4. Check peers

```bash
curl -s -X POST --data '{"jsonrpc":"2.0","id":1,"method":"info.peers"}' \
  -H 'content-type:application/json;' http://localhost:9650/ext/info | jq '.result.numPeers'
```

## Deep Dive

### Process status

```bash
systemctl status avalanchego
journalctl -u avalanchego --since "30 min ago" --no-pager | tail -100
```

### Network connectivity

```bash
# Check if ports are open
ss -tlnp | grep -E "9650|9651"

# Check firewall rules
sudo iptables -L -n | grep -E "9650|9651"
```

### Disk and I/O performance

```bash
# Check database size
du -sh /var/lib/avalanchego/db/

# Check disk I/O
iostat -x 1 5
```

### Version check

```bash
curl -s -X POST --data '{"jsonrpc":"2.0","id":1,"method":"info.getNodeVersion"}' \
  -H 'content-type:application/json;' http://localhost:9650/ext/info | jq .
```

## Remediation

### Restart the node

```bash
sudo systemctl restart avalanchego
```

### If stuck bootstrapping

Consider deleting the database and re-syncing:
```bash
sudo systemctl stop avalanchego
# Back up and remove the database
sudo mv /var/lib/avalanchego/db/ /var/lib/avalanchego/db.bak/
sudo systemctl start avalanchego
```

### If version is outdated

```bash
# Update AvalancheGo to latest version
# Follow the official upgrade guide for your installation method
```

## Escalation

- If rewarding stake continues to drop: check for network-wide issues
- If node cannot bootstrap: verify hardware meets minimum requirements (CPU, RAM, SSD)
- If peers are consistently low: check network configuration, firewall rules, and ISP connectivity

## References

- [Dashboard: Avalanche Validator](../dashboards/chain/)
- [Avalanche node docs](https://docs.avax.network/nodes)
