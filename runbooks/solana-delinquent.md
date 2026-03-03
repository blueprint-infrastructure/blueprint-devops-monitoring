# Solana Validator Delinquency

**Alerts:** SolanaValidatorDelinquent, SolanaNodeUnhealthy, SolanaNodeNotSynced, SolanaBlocksBehind, SolanaBlocksSeverelyBehind, SolanaVotesBehind, SolanaLowPeers, SolanaNoPeers, SolanaVersionDrift

## Symptoms

- Validator marked as delinquent (not voting)
- Node health check failing
- Node falling behind network slot height
- Vote account lagging behind confirmed slots
- Low or no peer connections

**Impact:** Delinquent validators do not earn rewards and may lose stake delegation.

## Immediate Actions

### 1. Check validator status

```bash
solana validators --url localhost | grep $(solana-keygen pubkey /path/to/identity.json)
solana catchup --our-localhost
```

### 2. Check node health

```bash
curl -s http://localhost:8899 -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' | jq .
```

### 3. Check sync status

```bash
solana catchup --our-localhost
solana slot
solana block-height
```

### 4. Check vote account

```bash
solana vote-account <VOTE_PUBKEY> --url localhost
solana vote-account <VOTE_PUBKEY> --url mainnet-beta  # Compare with mainnet
```

## Deep Dive

### Process status

```bash
# Check if validator process is running
systemctl status solana-validator
# or
ps aux | grep -E "solana-validator|agave-validator"

# Check logs
journalctl -u solana-validator --since "30 min ago" --no-pager | tail -100
```

### Network connectivity

```bash
# Check gossip peers
solana gossip --url localhost | wc -l

# Check network connections
ss -tnp | grep -E "8000|8001|8899|8900" | wc -l
```

### Resource issues

```bash
# Check disk I/O (ledger/accounts can be I/O heavy)
iostat -x 1 5

# Check memory (Solana requires significant RAM)
free -h

# Check open file descriptors
ls /proc/$(pgrep solana-validator)/fd | wc -l
ulimit -n
```

### Version check

```bash
solana --version
# Compare with cluster version
solana feature status --url mainnet-beta
```

## Remediation

### If behind and catching up

Wait for the node to catch up. Monitor with:
```bash
watch solana catchup --our-localhost
```

### If stuck or crashed

```bash
sudo systemctl restart solana-validator
```

### If severely behind (>1000 slots)

Consider restarting with a fresh snapshot:
```bash
# Download latest snapshot and restart
solana-validator --no-snapshot-fetch exit --force
# Then restart the service
```

### If delinquent due to version

```bash
# Update to latest version
solana-install update
sudo systemctl restart solana-validator
```

## Escalation

- If validator stays delinquent after restart: check for network-wide issues on Solana Discord
- If consistently behind: evaluate hardware (NVMe SSD, RAM, CPU requirements)
- If vote account issues: verify vote account authority and commission settings

## References

- [Dashboard: Solana Validator](../dashboards/chain/)
- [Solana validator docs](https://docs.solanalabs.com/operations)
