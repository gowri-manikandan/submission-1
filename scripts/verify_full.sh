#!/bin/bash
KEYS="${1:-1000}"
TARGET_VERSION="${2:-}"
FAIL_COUNT=0

pass() { echo "  PASS — $1"; }
fail() { echo "  FAIL — $1"; ((FAIL_COUNT++)); }

echo "=== Full Verification ==="
echo ""

# --- Check 1: Data integrity ---
echo "[1/5] Data integrity"
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
if [[ $missing -eq 0 && $mismatch -eq 0 ]]; then
  pass "$KEYS/$KEYS keys verified"
else
  fail "$missing missing, $mismatch mismatched"
fi

# --- Check 2: Version consistency ---
echo "[2/5] Version consistency"
VERSIONS=$(redis-cli cluster nodes | awk '{print $2}' | cut -d@ -f1 | sort -u | while read -r addr; do
  host=$(echo "$addr" | cut -d: -f1)
  port=$(echo "$addr" | cut -d: -f2)
  redis-cli -h "$host" -p "$port" INFO server | grep '^redis_version:' | cut -d: -f2 | tr -d '\t\r'
done | sort -u)

VERSION_COUNT=$(echo "$VERSIONS" | wc -l)
if [[ "$VERSION_COUNT" -eq 1 ]]; then
  ONLY_VERSION=$(echo "$VERSIONS" | head -1)
  if [[ -n "$TARGET_VERSION" && "$ONLY_VERSION" != "$TARGET_VERSION" ]]; then
    fail "all nodes on v$ONLY_VERSION (expected v$TARGET_VERSION)"
  else
    pass "all nodes on v$ONLY_VERSION"
  fi
else
    fail "mixed versions: $(echo "$VERSIONS" | paste -sd',' - | sed 's/,/, /g')"
fi

# --- Check 3: Topology health ---
echo "[3/5] Topology health"
slots=$(redis-cli cluster info | grep '^cluster_slots_assigned:' | cut -d: -f2 | tr -d '[:space:]')
masters=$(redis-cli cluster nodes | awk '$3 ~ /master/ {print $1}')
REPLICA_ISSUE=0
for mid in $masters; do
  replicas=$(redis-cli cluster nodes | awk -v m="$mid" '$4 == m && $3 ~ /slave/ {count++} END {print count+0}')
  if [[ "$replicas" -lt 1 ]]; then
    REPLICA_ISSUE=1
  fi
done
if [[ "$slots" == "16384" && "$REPLICA_ISSUE" -eq 0 ]]; then
  pass "16384 slots assigned, every master has a replica"
else
  fail "slots=$slots (expected 16384) or missing replica(s)"
fi

# --- Check 4: Cluster state ---
echo "[4/5] Cluster state"
state=$(redis-cli cluster info | grep '^cluster_state:' | cut -d: -f2 | tr -d '[:space:]')
if [[ "$state" == "ok" ]]; then
  pass "cluster_state=ok"
else
  fail "cluster_state=$state"
fi

# --- Check 5: Replication lag ---
echo "[5/5] Replication health"
REPL_DOWN=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  [[ $(awk '{print $3}' <<< "$line") != *slave* ]] && continue
  addr=$(awk '{print $2}' <<< "$line" | cut -d@ -f1)
  host=$(cut -d: -f1 <<< "$addr")
  port=$(cut -d: -f2 <<< "$addr")
  link=$(redis-cli -h "$host" -p "$port" INFO replication | grep '^master_link_status:' | cut -d: -f2 | tr -d '[:space:]')
  if [[ "$link" != "up" ]]; then
    ((REPL_DOWN++))
  fi
done < <(redis-cli cluster nodes)

if [[ "$REPL_DOWN" -eq 0 ]]; then
  pass "all replicas master_link_status=up"
else
  fail "$REPL_DOWN replica(s) with master_link_status down"
fi

echo ""
if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo "OVERALL: PASS — all 5 checks passed"
  exit 0
else
  echo "OVERALL: FAIL — $FAIL_COUNT check(s) failed"
  exit 1
fi
