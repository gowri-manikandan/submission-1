#!/bin/bash
KEYS="${1:-1000}"

echo "Seeding $KEYS keys into cluster..."

for i in $(seq -w 1 "$KEYS"); do
  key="key:$i"
  value=$(echo -n "$key" | sha256sum | awk '{print $1}')
  redis-cli -c SET "$key" "$value" > /dev/null
done

echo "Done — seeded $KEYS keys"
