#!/bin/bash

state=$(redis-cli cluster info | grep '^cluster_state:' | cut -d: -f2 | tr -d '[:space:]')
echo "Cluster State: $state"
echo ""

# Build map: master_node_id -> ip:port
declare -A MASTER_ADDR
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  id=$(awk '{print $1}' <<< "$line")
  addr=$(awk '{print $2}' <<< "$line" | cut -d@ -f1)
  role=$(awk '{print $3}' <<< "$line")
  if [[ "$role" == *master* ]]; then
    MASTER_ADDR[$id]=$addr
  fi
done < <(redis-cli cluster nodes)

echo "MASTERS"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  role=$(awk '{print $3}' <<< "$line")
  [[ "$role" != *master* ]] && continue

  addr=$(awk '{print $2}' <<< "$line" | cut -d@ -f1)
  host=$(cut -d: -f1 <<< "$addr")
  port=$(cut -d: -f2 <<< "$addr")
    if [[ "$line" == *" connected "* ]]; then
    slots=$(sed 's/.*connected //' <<< "$line")
  else
    slots="(none)"
  fi

  version=$(redis-cli -h "$host" -p "$port" INFO server | grep '^redis_version:' | cut -d: -f2 | tr -d '[:space:]')
  keys=$(redis-cli -h "$host" -p "$port" DBSIZE | tr -d '[:space:]')
  mem=$(redis-cli -h "$host" -p "$port" INFO memory | grep '^used_memory_human:' | cut -d: -f2 | tr -d '[:space:]')

  echo "$addr  [master]  v$version  slots: $slots  keys: $keys  mem: $mem"
done < <(redis-cli cluster nodes)

echo ""
echo "REPLICAS"
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  role=$(awk '{print $3}' <<< "$line")
  [[ "$role" != *slave* ]] && continue

  addr=$(awk '{print $2}' <<< "$line" | cut -d@ -f1)
  host=$(cut -d: -f1 <<< "$addr")
  port=$(cut -d: -f2 <<< "$addr")
  master_id=$(awk '{print $4}' <<< "$line")
  replicating=${MASTER_ADDR[$master_id]:-unknown}

  version=$(redis-cli -h "$host" -p "$port" INFO server | grep '^redis_version:' | cut -d: -f2 | tr -d '[:space:]')
  mem=$(redis-cli -h "$host" -p "$port" INFO memory | grep '^used_memory_human:' | cut -d: -f2 | tr -d '[:space:]')

  echo "$addr  [replica]  v$version  replicating: $replicating  mem: $mem"
done < <(redis-cli cluster nodes)
