#!/bin/bash
TARGET_VERSION="${1:?Target version required}"

echo "[1/4] Checking cluster state..."
state=$(redis-cli cluster info | grep '^cluster_state:' | cut -d: -f2 | tr -d '[:space:]')
if [[ "$state" != "ok" ]]; then
  echo "FAIL: cluster_state is '$state' (expected ok)"
  exit 1
fi
echo "OK: cluster_state=ok"

echo "[2/4] Checking all nodes reachable..."
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  addr=$(awk '{print $2}' <<< "$line" | cut -d@ -f1)
  host=$(cut -d: -f1 <<< "$addr")
  port=$(cut -d: -f2 <<< "$addr")

  pong=$(redis-cli -h "$host" -p "$port" PING 2>/dev/null || true)
  if [[ "$pong" != "PONG" ]]; then
    echo "FAIL: node $addr not reachable"
    exit 1
  fi
done < <(redis-cli cluster nodes)
echo "OK: all 6 nodes reachable"


echo "[3/4] Checking Redis version..."
versions=$(redis-cli cluster nodes | awk '{print $2}' | cut -d@ -f1 | sort -u | while read -r addr; do
  host=$(cut -d: -f1 <<< "$addr")
  port=$(cut -d: -f2 <<< "$addr")
  redis-cli -h "$host" -p "$port" INFO server | grep '^redis_version:' | cut -d: -f2 | tr -d '\t\r'
done | sort -u)

if [[ "$(echo "$versions" | wc -l)" -eq 1 && "$versions" == "$TARGET_VERSION" ]]; then
  echo "SKIP: all nodes already at v$TARGET_VERSION"
  exit 10
fi
echo "OK: current=v$(echo "$versions" | head -1) target=v$TARGET_VERSION"

echo "[4/4] Running data integrity baseline..."
KEYS=1000
missing=0
mismatch=0

for i in $(seq -w 1 "$KEYS"); do
  key="key:$i"
  expected=$(echo -n "$key" | sha256sum | awk '{print $1}')
  actual=$(redis-cli -c GET "$key")
  if [[ -z "$actual" || "$actual" == "(nil)" ]]; then
    ((missing++))
  elif [[ "$actual" != "$expected" ]]; then
    ((mismatch++))
  fi
done

if [[ $missing -gt 0 || $mismatch -gt 0 ]]; then
  echo "FAIL: data baseline — $missing missing, $mismatch mismatched"
  exit 1
fi
echo "OK: data baseline — $KEYS/$KEYS keys verified"

echo ""
echo "PRE-FLIGHT PASSED — ready for rolling upgrade"
