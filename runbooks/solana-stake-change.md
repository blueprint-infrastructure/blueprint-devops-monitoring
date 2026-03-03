# Solana Stake Change Monitoring

**Alerts:** SolanaStakeSignificantChange

## Symptoms

- Validator activated stake has changed by more than 10% in the last 24 hours

**Impact:** Significant stake changes may indicate delegator movement, stake account issues, or network events. Large stake decreases reduce the validator's influence and potential rewards.

## Immediate Actions

### 1. Check current stake

```bash
solana stakes <VOTE_PUBKEY> --url localhost
solana vote-account <VOTE_PUBKEY> --url localhost
```

### 2. Determine direction of change

Check if stake increased or decreased:
```bash
# Check activated stake
solana validators --url localhost | grep $(solana-keygen pubkey /path/to/identity.json)
```

### 3. Review recent stake account activity

```bash
# List stake accounts delegated to this validator
solana stakes <VOTE_PUBKEY> --url mainnet-beta
```

## Deep Dive

### Stake decrease investigation

Common causes:
- Delegator withdrew stake
- Stake account deactivated
- Validator commission change triggered delegator exits
- Validator downtime caused delegators to redelegate

```bash
# Check validator uptime and skip rate
solana validators --url mainnet-beta | grep <IDENTITY_PUBKEY>

# Check recent epoch performance
solana epoch-info --url mainnet-beta
```

### Stake increase investigation

Common causes:
- New delegation received
- Stake accounts activated (after warmup period)
- Foundation or grant delegation

### Check validator metrics

```bash
# Commission rate
solana vote-account <VOTE_PUBKEY> --url mainnet-beta | grep "Commission"

# Skip rate
solana validators --url mainnet-beta --sort skip-rate | head -20
```

## Remediation

### If stake decreased due to poor performance

1. Investigate and resolve any performance issues (see [solana-delinquent.md](solana-delinquent.md))
2. Monitor skip rate and ensure it stays low
3. Verify hardware meets current requirements

### If unexpected stake movement

1. Verify vote account authority hasn't been compromised
2. Check for any unauthorized commission changes
3. Review recent transactions on the vote account

### Monitor recovery

```bash
# Watch stake changes over time
watch -n 60 'solana validators --url localhost | grep <IDENTITY_PUBKEY>'
```

## Escalation

- If stake decreases without explanation: audit vote account authority and recent transactions
- If widespread: check for network-wide events (epoch changes, protocol updates)
- If vote account compromise suspected: immediately take steps to secure keys

## References

- [Dashboard: Solana Validator](../dashboards/chain/)
- [Solana staking docs](https://docs.solanalabs.com/operations/guides/validator-stake)
