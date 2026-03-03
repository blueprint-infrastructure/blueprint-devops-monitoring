# Audius Claims Address ETH Balance

**Alerts:** AudiusClaimsBalanceLow, AudiusClaimsBalanceCritical

## Symptoms

- Audius claims address ETH balance below 0.1 ETH (warning)
- Audius claims address ETH balance below 0.04 ETH (critical)

**Impact:** The claims address needs ETH to pay for gas fees when processing claims transactions. If the balance reaches zero, claim processing will stop.

## Immediate Actions

### 1. Verify current balance

```bash
# Using eth RPC directly
curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_getBalance","params":["<CLAIMS_ADDRESS>","latest"],"id":1}' \
  -H "Content-Type: application/json" http://localhost:8545 | jq -r '.result' | xargs printf "%d\n" | awk '{printf "%.6f ETH\n", $1/1e18}'
```

### 2. Check recent transactions

Review recent transactions from the claims address on Etherscan to understand the spend rate.

### 3. Estimate time to depletion

Based on average gas usage per claim and current gas prices, estimate how long the remaining balance will last.

## Deep Dive

### Gas price analysis

```bash
# Check current gas price
curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_gasPrice","params":[],"id":1}' \
  -H "Content-Type: application/json" http://localhost:8545 | jq -r '.result' | xargs printf "%d\n" | awk '{printf "%.2f Gwei\n", $1/1e9}'
```

### Transaction history

Check the claims address transaction history for:
- Average gas cost per claim
- Claim frequency
- Any unusual spending patterns

## Remediation

### Fund the claims address

Transfer ETH to the claims address from the designated funding wallet:

1. Calculate the amount needed (recommended: fund to 0.5 ETH)
2. Send ETH from the funding wallet to the claims address
3. Verify the balance after the transaction confirms

### Verify balance after funding

```bash
curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_getBalance","params":["<CLAIMS_ADDRESS>","latest"],"id":1}' \
  -H "Content-Type: application/json" http://localhost:8545 | jq -r '.result' | xargs printf "%d\n" | awk '{printf "%.6f ETH\n", $1/1e18}'
```

## Escalation

- If balance drains faster than expected: investigate for unauthorized transactions
- If gas prices are abnormally high: consider waiting for lower gas or increasing the funding amount
- If claims are failing: check the claims contract and Audius service status

## References

- [Dashboard: Ethereum Validator](../dashboards/chain/)
- [Etherscan](https://etherscan.io/)
