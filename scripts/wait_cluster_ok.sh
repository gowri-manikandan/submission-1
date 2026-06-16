#!/bin/bash
for i in $(seq 1 30); do
  state=$(redis-cli cluster info | grep '^cluster_state:' | cut -d: -f2 | tr -d '[:space:]')
  if [[ "$state" == "ok" ]]; then
    echo "cluster: ok"
    exit 0
  fi
  sleep 2
done
echo "cluster: fail (timeout)"
exit 1
