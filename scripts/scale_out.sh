#!/bin/bash
# Runs ON node-1. Joins a new master + replica pair to the cluster and rebalances slots.
# Uses CLUSTER MEET / CLUSTER REPLICATE instead of `redis-cli --cluster add-node`,
# because add-node copies Redis Functions (FUNCTION DUMP/RESTORE) and that step is
# fragile in Redis 7.x ("DUMP payload version or checksum are wrong"). MEET avoids it.
# Usage: scale_out.sh <new_master_ip> <new_replica_ip>
NEW_MASTER_IP="${1:?new master IP required}"
NEW_REPLICA_IP="${2:?new replica IP required}"
ANCHOR_IP="10.10.0.11"   # any existing cluster member to gossip through

echo "Joining new master $NEW_MASTER_IP to the cluster (CLUSTER MEET)..."
redis-cli -h "$NEW_MASTER_IP" -p 6379 CLUSTER MEET "$ANCHOR_IP" 6379

echo "Joining new replica $NEW_REPLICA_IP to the cluster (CLUSTER MEET)..."
redis-cli -h "$NEW_REPLICA_IP" -p 6379 CLUSTER MEET "$ANCHOR_IP" 6379

# Wait until node-1 sees the new master, then grab its node id.
# head -1 guards against a stale duplicate line for the same IP.
MASTER_ID=""
for i in $(seq 1 20); do
  MASTER_ID=$(redis-cli cluster nodes | grep -F -w "$NEW_MASTER_IP" | awk '{print $1}' | head -1)
  [[ -n "$MASTER_ID" ]] && break
  sleep 1
done
if [[ -z "$MASTER_ID" ]]; then
  echo "FAIL: new master $NEW_MASTER_IP did not appear after CLUSTER MEET"
  exit 1
fi
echo "New master node id: $MASTER_ID"

# Make the new replica follow the new master. Re-read the master id on every
# attempt, because a node can change its id if it restarts / re-handshakes.
echo "Setting $NEW_REPLICA_IP to replicate the new master..."
ok=0
for i in $(seq 1 30); do
  MASTER_ID=$(redis-cli cluster nodes | grep -F -w "$NEW_MASTER_IP" | awk '{print $1}' | head -1)
  if [[ -n "$MASTER_ID" ]] && \
     redis-cli -h "$NEW_REPLICA_IP" -p 6379 CLUSTER REPLICATE "$MASTER_ID" 2>/dev/null | grep -q "OK"; then
    ok=1; break
  fi
  sleep 1
done
if [[ "$ok" != "1" ]]; then
  echo "FAIL: could not make $NEW_REPLICA_IP a replica of (current id of $NEW_MASTER_IP)"
  exit 1
fi

echo "Repairing any half-finished slot migrations before rebalancing..."
redis-cli --cluster fix "$ANCHOR_IP:6379"

echo "Rebalancing hash slots across all masters (fills the empty new master)..."
redis-cli --cluster rebalance "$ANCHOR_IP:6379" --cluster-use-empty-masters

echo "scale-out: done"
