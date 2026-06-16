#!/bin/bash
REPLICA_IP="${1:?Replica IP required}"
MASTER_IP="${2:-}"

echo "Triggering CLUSTER FAILOVER on replica $REPLICA_IP..."

# Must be a replica before failover
role=$(redis-cli cluster nodes | grep -F -w "$REPLICA_IP" | awk '{print $3}')
if [[ "$role" != *slave* ]]; then
  echo "FAIL: $REPLICA_IP is not a replica (role=$role). Cannot failover."
  exit 1
fi

result=$(redis-cli -h "$REPLICA_IP" -p 6379 CLUSTER FAILOVER 2>&1)
if [[ "$result" == ERR* ]]; then
  echo "FAIL: $result"
  exit 1
fi

echo "Waiting for failover..."
for i in $(seq 1 30); do
  replica_role=$(redis-cli cluster nodes | grep -F -w "$REPLICA_IP" | awk '{print $3}')
  if [[ "$replica_role" == *master* ]]; then
    if [[ -n "$MASTER_IP" ]]; then
      master_role=$(redis-cli cluster nodes | grep -F -w "$MASTER_IP" | awk '{print $3}')
      if [[ "$master_role" != *slave* && "$master_role" != *master* ]]; then
        sleep 2
        continue
      fi
      echo "Failover complete — $REPLICA_IP is master, $MASTER_IP is replica"
    else
      echo "Failover complete — $REPLICA_IP is now master"
    fi
    exit 0
  fi
  sleep 2
done

echo "FAIL: failover timed out"
exit 1
