#!/bin/bash
KEYS="${1:-1000}"

missing=0
mismatch=0
verified=0

echo "Verifying $KEYS keys..."

for i in $(seq -w 1 "$KEYS"); do
  key="key:$i"
  expected=$(echo -n "$key" | sha256sum | awk '{print $1}')
  actual=$(redis-cli -c GET "$key")

  if [[ -z "$actual" || "$actual" == "(nil)" ]]; then
    ((missing++))
  elif [[ "$actual" != "$expected" ]]; then
    ((mismatch++))
  else
    ((verified++))
  fi
done

if [[ $missing -eq 0 && $mismatch -eq 0 ]]; then
  echo "PASS — $verified/$KEYS keys verified"
  exit 0
else
  echo "FAIL — $missing keys missing, $mismatch values mismatched"
  exit 1
fi
