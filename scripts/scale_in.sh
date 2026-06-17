#!/bin/bash
# Runs ON node-1. Scale IN: migrate all slots off a master, then remove it + its replica(s).
# Usage: scale_in.sh <master-node-id>
MASTER_ID="${1:?master node-id required}"
ANCHOR="127.0.0.1:6379"     # surviving cluster member used as the reference node

# Look up the target and confirm it is a master.
# Match the node-id in field 1 ONLY. A plain `grep -w "$MASTER_ID"` also matches
# every replica line (replicas carry their master's id in field 4), so with head -1
# we could grab a replica line and wrongly conclude "not a master".
LINE=$(redis-cli cluster nodes | awk -v id="$MASTER_ID" '$1==id {print; exit}')
if [[ -z "$LINE" ]]; then
  echo "FAIL: node id $MASTER_ID not found in the cluster"
  exit 1
fi
ROLE=$(awk '{print $3}' <<< "$LINE")
if [[ "$ROLE" != *master* ]]; then
  echo "FAIL: $MASTER_ID is role '$ROLE', not a master — pass a MASTER node-id"
  exit 1
fi
MASTER_ADDR=$(awk '{print $2}' <<< "$LINE" | cut -d@ -f1)
MASTER_HOST=$(cut -d: -f1 <<< "$MASTER_ADDR")
echo "Scale-in target: master $MASTER_ADDR (id $MASTER_ID)"

# Find this master's replica(s) BEFORE we change anything.
REPLICA_IDS=$(redis-cli cluster nodes | awk -v m="$MASTER_ID" '$3 ~ /slave/ && $4 == m {print $1}')

# 1. Migrate ALL slots off the master (weight 0 = it should own no slots).
echo "Migrating all slots off $MASTER_ADDR ..."
redis-cli --cluster rebalance "$ANCHOR" --cluster-weight "${MASTER_ID}=0"

# Confirm the master is now empty before removing it (else data would be lost).
# Read the slots fields (9..NF) of the target's OWN line only; non-empty = still owns slots.
sleep 2
SLOTS=$(redis-cli cluster nodes | awk -v id="$MASTER_ID" '$1==id {for(i=9;i<=NF;i++) printf "%s ",$i}')
if [[ -n "${SLOTS// /}" ]]; then
  echo "FAIL: master still owns slots after rebalance — re-run scale-in"
  exit 1
fi

# 2. Remove the replica(s) first.
for rid in $REPLICA_IDS; do
  RADDR=$(redis-cli cluster nodes | awk -v id="$rid" '$1==id {print $2; exit}' | cut -d@ -f1)
  echo "Removing replica $RADDR (id $rid)..."
  redis-cli --cluster del-node "$ANCHOR" "$rid"
  echo "REMOVED_IP=$(cut -d: -f1 <<< "$RADDR")"
done

# 3. Remove the now-empty master.
echo "Removing master $MASTER_ADDR (id $MASTER_ID)..."
redis-cli --cluster del-node "$ANCHOR" "$MASTER_ID"
echo "REMOVED_IP=$MASTER_HOST"

echo "scale-in: done"
