#!/bin/bash
# Output one pair per line:  MASTER_IP  REPLICA_IP
# Example: 10.10.0.11 10.10.0.15

declare -A ID_TO_IP

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  id=$(awk '{print $1}' <<< "$line")
  ip=$(awk '{print $2}' <<< "$line" | cut -d@ -f1 | cut -d: -f1)
  ID_TO_IP["$id"]="$ip"
done < <(redis-cli cluster nodes)

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  role=$(awk '{print $3}' <<< "$line")
  [[ "$role" != *slave* ]] && continue

  replica_ip=$(awk '{print $2}' <<< "$line" | cut -d@ -f1 | cut -d: -f1)
  master_id=$(awk '{print $4}' <<< "$line")
  master_ip="${ID_TO_IP[$master_id]}"

  if [[ -n "$master_ip" && -n "$replica_ip" ]]; then
    echo "$master_ip $replica_ip"
  fi
done < <(redis-cli cluster nodes)
