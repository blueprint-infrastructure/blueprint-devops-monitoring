# Algorand Participation Key Renewal

**Alerts:** AlgorandParticipationKeyExpiring, AlgorandParticipationKeyCritical, AlgorandNodeUnhealthy, AlgorandNodeNotReady, AlgorandNodeNotSynced, AlgorandRoundsBehind, AlgorandRoundsSeverelyBehind, AlgorandLowPeers, AlgorandVersionDrift

## Symptoms

- Participation key has fewer than 600,000 rounds remaining (warning)
- Participation key has fewer than 300,000 rounds remaining (critical)
- Node health or readiness checks failing
- Node falling behind network round

**Impact:** When a participation key expires, the node stops participating in consensus. A new key must be generated and registered before expiry.

## Immediate Actions

### 1. Check participation key status

```bash
goal account partkeyinfo
```

### 2. Check current round vs key expiry

```bash
# Current round
goal node status | grep "Last committed block"

# Key valid range
goal account partkeyinfo | grep -E "First valid|Last valid"
```

### 3. Check node health

```bash
goal node status
goal node status -w 1000  # Watch mode
```

## Deep Dive

### Calculate rounds remaining

```bash
CURRENT_ROUND=$(goal node status | grep "Last committed block" | awk '{print $NF}')
LAST_VALID=$(goal account partkeyinfo | grep "Last valid" | awk '{print $NF}')
echo "Rounds remaining: $((LAST_VALID - CURRENT_ROUND))"
echo "Approximate days remaining: $(( (LAST_VALID - CURRENT_ROUND) * 3 / 86400 ))"
```

### Check node sync status

```bash
goal node status
# "Sync Time" should be close to 0
# "Last committed block" should match network
```

### Check network connectivity

```bash
goal node status | grep "Network"
```

## Remediation

### Generate new participation key

```bash
# Generate key for next 3,000,000 rounds (~104 days at ~3s/round)
CURRENT_ROUND=$(goal node status | grep "Last committed block" | awk '{print $NF}')
LAST_ROUND=$((CURRENT_ROUND + 3000000))

goal account addpartkey \
  -a <ACCOUNT_ADDRESS> \
  --roundFirstValid $CURRENT_ROUND \
  --roundLastValid $LAST_ROUND
```

### Register the new key online

```bash
goal account changeonlinestatus \
  -a <ACCOUNT_ADDRESS> \
  --online
```

### Verify registration

```bash
goal account partkeyinfo
goal account dump -a <ACCOUNT_ADDRESS> | jq '.onl'
```

### Restart node if unhealthy

```bash
goal node restart
# or
sudo systemctl restart algorand
```

## Escalation

- If key generation fails: check disk space and node status
- If registration transaction fails: check account balance for minimum fee
- If node cannot sync: verify network connectivity and check for network upgrades

## References

- [Dashboard: Algorand Validator](../dashboards/chain/)
- [Algorand participation guide](https://developer.algorand.org/docs/run-a-node/participate/)
