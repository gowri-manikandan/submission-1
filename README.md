# Redis Cluster Lifecycle Tool

**One CLI to provision, operate, upgrade, scale, and roll back a 6-node Redis Cluster — Ansible-driven, container-based, zero-downtime.**

![Bash](https://img.shields.io/badge/Bash-4EAA25?logo=gnubash&logoColor=white)
![Ansible](https://img.shields.io/badge/Ansible-2.14%2B-EE0000?logo=ansible&logoColor=white)
![Redis](https://img.shields.io/badge/Redis-7.0%20to%207.2-DC382D?logo=redis&logoColor=white)
![Podman](https://img.shields.io/badge/Podman-supported-892CA0?logo=podman&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-supported-2496ED?logo=docker&logoColor=white)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS-lightgrey)

A single command-line tool (`redis-tool`) that manages the full lifecycle of a **6-node Redis Cluster**
(3 masters + 3 replicas) running inside Docker or Podman containers. Everything is driven through one
CLI — no manual SSH, no hand-typed `redis-cli`. The CLI orchestrates **Ansible**, which does the real
work on the nodes over SSH.


---

## Table of Contents

- [Features](#features)
- [Quickstart](#quickstart)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Setup](#setup)
- [Command Reference](#command-reference)
- [Stretch Goals](#stretch-goals)
- [Rolling Upgrade Strategy](#rolling-upgrade-strategy)
- [How the Exact Version Is Installed](#how-the-exact-version-is-installed)
- [Rollback in Depth](#rollback-in-depth)
- [Design Notes & Limitations](#design-notes--limitations)
- [Project Layout](#project-layout)
- [Troubleshooting](#troubleshooting)

---

## Features

| | Capability | Command |
|---|---|---|
| 🚀 | **Provision** a 3-master / 3-replica cluster at an exact Redis version | `provision` |
| 🌱 | **Seed & verify** 1000 keys with reproducible (`SHA256`) values | `data seed` / `data verify` |
| 📊 | **Status** — topology, slots, key counts, versions, memory | `status` |
| ♻️ | **Rolling upgrade** with zero client-visible downtime | `upgrade` |
| ✅ | **Full health check** — integrity, version, slots, state, replication | `verify --full` |
| ➕ | **Scale out** — add a master + replica and rebalance slots | `scale --add-nodes 2` |
| ➖ | **Scale in** — drain a master, remove it and its replica | `scale --remove-node <id>` |
| ⏮️ | **Rollback** a partial/aborted upgrade | `rollback` |
| 🧾 | **Structured logging** — one JSON-lines audit file | `logs/redis-tool.jsonl` |

---

## Quickstart

```bash
# 0. One-time host setup (deps, SSH key, build context)
./setup.sh

# 1. Start the 6 "servers" (pick the line for your runtime)
cd infra && docker compose up -d --build && cd ..      # Docker
cd infra && podman-compose up -d --build && cd ..      # Podman

# 2. Build the cluster, seed data, and check health
./redis-tool provision --version 7.0.15 --masters 3 --replicas-per-master 1
./redis-tool data seed --keys 1000
./redis-tool data verify --keys 1000
./redis-tool status

# 3. Rolling upgrade (zero downtime) + full verification
./redis-tool upgrade --target-version 7.2.6 --strategy rolling
./redis-tool verify --full
```

> **Note — Podman users:** Podman < 4.1 has no built-in `podman compose`. Install the standalone tool
> first: `pip3 install --user podman-compose`. See [Setup](#setup).

---

## Architecture

```
  YOUR LAPTOP (control node)
  ┌───────────────────────────────────────────────┐
  │  ./redis-tool <command> ...   (bash CLI)        │
  │       │  1. prerequisite check (runtime + ansible)
  │       │  2. log_event → logs/redis-tool.jsonl   │
  │       ▼                                         │
  │  ansible-playbook  +  helper scripts (run on node-1)
  └───────┬─────────────────────────────────────────┘
          │ SSH (host ports 2201–2208 → container :22)
          ▼
  Containers = "servers", all on network 10.10.0.0/24
    redis-node-1 (10.10.0.11) ┐
    redis-node-2 (10.10.0.12) │ 3 masters
    redis-node-3 (10.10.0.13) ┘
    redis-node-4 (10.10.0.14) ┐
    redis-node-5 (10.10.0.15) │ 3 replicas
    redis-node-6 (10.10.0.16) ┘
    redis-node-7 (10.10.0.17) ┐ spares — OFF by default,
    redis-node-8 (10.10.0.18) ┘ started only by `scale --add-nodes 2`
```

**Layers**

| Layer | Role |
|-------|------|
| **`redis-tool`** (bash) | The CLI. *Orchestrates only* — parses commands, calls Ansible / helper scripts, logs every step. |
| **Ansible** | Installs Redis (compiled from source for an exact version), writes config, starts Redis, forms the cluster. |
| **Docker / Podman** | 6 (+2 spare) Ubuntu containers acting as remote servers with SSH. |

**Lifecycle order**

```
setup → start containers → provision → data seed → data verify → status
      → upgrade → verify --full          (core task)
      → scale out / scale in / rollback  (stretch goals)
```

Every command runs the prerequisite check first, then appends its actions to a single log file,
`logs/redis-tool.jsonl`.

---

## Prerequisites

On **every** run the tool auto-checks the first two rows (container runtime + a compose tool, and
Ansible) and stops with install instructions if either is missing. The SSH key and the containers'
internet access are also required, but are **not** auto-checked — `setup.sh` handles the key, and you
must ensure the containers can reach the internet yourself.

| Requirement | Auto-checked? | Why | Install |
|------|:---:|-----|---------|
| Docker **or** Podman (Podman preferred) | ✅ | Runs the containers | https://podman.io/docs/installation · https://docs.docker.com/engine/install/ |
| A compose tool: `docker compose` (v2) **or** `podman-compose` | ✅ | Used by setup and `scale` | Podman < 4.1 has no built-in `podman compose` → `pip3 install --user podman-compose` |
| Ansible **2.14+** (`ansible-playbook`) | ✅ | Configures the nodes | `pip install 'ansible>=2.14'` |
| SSH key at `~/.ssh/id_rsa` | ❌ (setup.sh creates it) | Lets Ansible log into the containers | `ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""` |
| Internet **inside the containers** | ❌ | Redis is compiled from source (apt + download.redis.io) | corporate networks may need a proxy/mirror |

> **Important:** Redis is built from source so it matches the *exact* requested version
> (`apt install redis-server` only ships Ubuntu's 6.0.x). The containers must reach `archive.ubuntu.com`
> and `download.redis.io`.

---

## Setup

**Step 1 — run the setup script.** It checks/installs Docker & Ansible, creates your SSH key if
missing, copies the public key into the build context, and points `hosts.ini` at your key:

```bash
chmod +x setup.sh
./setup.sh                 # prompts before installing; use ./setup.sh --yes to auto-confirm
```

> **Note — Podman:** `setup.sh` auto-installs Docker and Ansible, but **not** `podman-compose`. If you
> use Podman < 4.1, install it yourself first: `pip3 install --user podman-compose`.

**Step 2 — build the image and start the 6 nodes.** The SSH public key is baked into the image, so
SSH works the moment a container starts.

```bash
# Docker
cd infra && docker compose up -d --build && docker compose ps && cd ..

# Podman
cd infra && podman-compose up -d --build && podman ps && cd ..
```

Expect 6 containers `Up`. Optional sanity check: `cd ansible && ansible redis_nodes -m ping && cd ..`
(expect `pong` ×6).

> **Warning — stay in one runtime context.** Rootless and rootful (`sudo`) Podman have **separate image
> stores and separate networks**. If you build/start node-1…6 rootless, run every later command rootless
> too (and vice versa) — otherwise the scaled-out node-7/8 can't see the existing cluster.

**Manual setup** (if you skip `setup.sh`):

```bash
cp ~/.ssh/id_rsa.pub infra/id_rsa.pub        # key into the build context
# edit ansible/inventory/hosts.ini so ansible_ssh_private_key_file → /home/<you>/.ssh/id_rsa
```

> **Warning:** the committed `hosts.ini` hardcodes `ansible_ssh_private_key_file=/home/kavin/.ssh/id_rsa`.
> If you skip `setup.sh` you **must** edit that line to your own key path, or every Ansible step fails to
> log in. `setup.sh` rewrites it for you automatically.

If you change your SSH key later, re-copy it to `infra/id_rsa.pub` and rebuild.

---

## Command Reference

Run everything from the project root. Each block states **what it does** and **what a healthy result
looks like**.

### `provision` — build the cluster

```bash
./redis-tool provision --version 7.0.15 --masters 3 --replicas-per-master 1
```

Compiles Redis **7.0.15** on all 6 nodes, writes cluster-mode config, starts Redis, and forms one
cluster (3 masters owning slots 0–16383, each with 1 replica).
*Healthy:* topology printed, `cluster_state:ok`.

### `data seed` / `data verify` — prove data integrity

```bash
./redis-tool data seed --keys 1000        # writes 1000 keys across the masters
./redis-tool data verify --keys 1000      # reads them back and recomputes
```

Each value is `SHA256(key name)`, so `verify` recomputes the expected value for every key — nothing is
stored separately. *Healthy:* `PASS — 1000/1000 keys verified`.

### `status` — cluster summary

```bash
./redis-tool status
```

Prints `Cluster State: ok`, then per node: IP, port, role, version, slot range + key count (masters),
which master a replica follows, and memory.

### `upgrade` — rolling upgrade (zero downtime)

```bash
./redis-tool data verify --keys 1000                          # pre-upgrade baseline
./redis-tool upgrade --target-version 7.2.6 --strategy rolling
```

Upgrades replicas first, then masters via failover (see [strategy](#rolling-upgrade-strategy)).
*Healthy:* ends with `UPGRADE COMPLETE — all nodes on v7.2.6, data integrity verified`.

### `verify --full` — comprehensive health check

```bash
./redis-tool verify --full
```

Five PASS/FAIL checks: **data integrity**, **version consistency**, **slot coverage** (all 16384
covered, every master has a replica), **cluster state ok**, **replication lag**
(`master_link_status:up`).

---

## Stretch Goals

### S1 · Scale out — add a master + replica, rebalance slots

```bash
./redis-tool scale --add-nodes 2
./redis-tool status        # 10.10.0.17 = new master (owns slots), 10.10.0.18 = its replica
```

Starts the 2 spare containers, installs Redis at the cluster's current version, joins them with
`CLUSTER MEET` (avoids the fragile `add-node` Functions copy), then rebalances slots so the new master
gets its share. The tool **fails loudly** if the rebalance never lands slots on the new master.

> **Note — the image must already exist.** Scale-out runs `up` **without** `--build`, and only
> `redis-node-1` has a `build:` block in `compose.yml`, so the `redis-ssh:latest` image must be present
> in the current runtime store. If it was pruned or built in a different context, rebuild first:
>
> ```bash
> cd infra && podman build -t redis-ssh:latest -f Containerfile .   # or: docker build -t redis-ssh:latest .
> ```

### S2 · Scale in — remove a master + its replica

```bash
# Needs the FULL 40-char node-id (NOT a short alias like "7"). Capture it first:
NODE_ID=$(ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR -p 2201 redis@127.0.0.1 \
  "redis-cli cluster nodes | awk '\$2 ~ /^10.10.0.17:/ {print \$1}'")
echo "Removing node-id: $NODE_ID"

./redis-tool scale --remove-node "$NODE_ID"
./redis-tool status        # back to 3 masters / 3 replicas, slots redistributed
```

Migrates all slots off the target master (weight-0 rebalance), confirms it owns no slots (so no data is
lost), removes its replica(s) then the master, and powers off the freed containers.

> **Tip — why the full node-id matters:** the tool matches the id in field 1 of `cluster nodes`. A short
> value like `7` can word-match unrelated fields (epochs, slot numbers) and behave nondeterministically —
> always pass the real id from `status` / the capture above.

### S3 · Rollback — undo a partial/aborted upgrade

```bash
./redis-tool rollback --target-version 7.0.15
```

Downgrades any node **ahead of** the target version (nodes already at the target are skipped). Each
rolled-back node is **wiped and re-syncs clean from its master** — which only works while old-version
masters are still alive. See [Rollback in Depth](#rollback-in-depth).

### S4 · Idempotency

Re-running `provision` on a healthy cluster is a no-op; running `upgrade` when every node is already on
the target prints "nothing to do" and exits cleanly with no failover.

### S5 · Structured logging

Every command appends JSON-lines to a single file, `logs/redis-tool.jsonl` (timestamp, command, node,
action, outcome).

```bash
cat logs/redis-tool.jsonl          # full history, all commands, one file
tail -f logs/redis-tool.jsonl      # follow live during a run
```

---

## Rolling Upgrade Strategy

The cluster must stay `cluster_state:ok` the entire time. The order is what makes it safe:

1. **Pre-flight** — cluster healthy? all nodes reachable? current version ≠ target? data baseline OK?
   If any fail, stop before touching anything. (If everything is already on the target, it prints
   "nothing to do" and exits — see S4.)
2. **Upgrade replicas first, one at a time** — a replica serves no slots, so taking one down loses
   neither data nor availability. Wait for `cluster:ok` after each.
3. **Upgrade masters with failover** — for each master, run `CLUSTER FAILOVER` on its already-upgraded
   replica so the replica becomes master (traffic moves to the new version), then upgrade the old master
   (now a replica) safely.
4. **Post-upgrade verification** — `data verify` + `status` prove zero data loss.

> One-line reason: **never take down a serving master before a newer replica has taken its place.**

---

## How the Exact Version Is Installed

Provision and upgrade share the same install logic (`roles/redis/tasks/install.yml`,
`upgrade_install.yml`):

1. Install build deps (`build-essential`, `tcl`, `wget`, …) via apt.
2. Remove any apt-installed Redis (so the wrong version can't shadow ours in `/usr/bin`).
3. Download `https://download.redis.io/releases/redis-<version>.tar.gz` and compile it into
   `/usr/local` — only if the running binary isn't already that version.
4. **Assert** the installed binary reports the requested version, or fail the play.

**Common pitfalls**

| Symptom | Cause | Fix |
|---|---|---|
| `get_url` 404 / "Could not download" | the version doesn't exist at download.redis.io (typo, or `7.2` instead of `7.2.6`) | pass a full, real version like `7.0.15` / `7.2.6` |
| Install "skips" but the wrong binary is present | the version check is a **substring** match — asking for `7.0.1` when `7.0.15` is installed matches | use exact patch versions that aren't prefixes of each other; verify with `status` |
| First provision/upgrade is slow | source compile on every node | expected — later runs reuse the binary |
| Compile / apt fails | container can't reach the internet | see [Prerequisites](#prerequisites) and [Troubleshooting](#troubleshooting) |

---

## Rollback in Depth

Rollback's mechanism: **stop the node → install the old version → wipe its data files → restart →
re-sync fresh from its master.** It wipes data on purpose, because an older Redis cannot read a newer
on-disk RDB; data is preserved because the node pulls a fresh copy from its master.

The catch: **the master it syncs from must be on the old version.**

> Redis 7.0 writes RDB **v10**. Redis 7.2 writes RDB **v11**. A 7.0 instance cannot load a v11 RDB.

**Case A — partial / aborted upgrade (works ✅).** Masters still on 7.0.15, replicas already on 7.2.6.
Rolling back the replicas downgrades them and they full-sync a v10 RDB from the still-7.0.15 masters →
success. **This is exactly what rollback is built for.**

**Case B — every node already on the new version (can't preserve data ❌).** With all 6 nodes on
7.2.6, `rollback --target-version 7.0.15` has no "everything is newer, nothing to do" guard, so it tries
to downgrade all six. The first replica downgrades to 7.0.15, wipes, and full-syncs from its master —
which is **still 7.2.6** — receiving a v11 RDB it cannot load (`Can't handle RDB format version 11`).
The sync never completes, `wait_cluster_ok` times out, and rollback prints **FAIL** at that node.

> **Important:** Rollback aborts a *partial* upgrade — it is **not** a downgrade tool for a fully
> upgraded cluster. To return a fully upgraded cluster to the old version, re-provision and re-seed:
>
> ```bash
> ./redis-tool provision --version 7.0.15 --masters 3 --replicas-per-master 1
> ./redis-tool data seed --keys 1000
> ```

**Test S3 the way it's designed** (force the partial-upgrade state by upgrading only the replicas):

```bash
# 1. Clean slate on the OLD version
./redis-tool provision --version 7.0.15 --masters 3 --replicas-per-master 1
./redis-tool data seed --keys 1000

# 2. Partial upgrade — bump ONLY the replicas to 7.2.6 (masters stay 7.0.15)
export ANSIBLE_CONFIG=ansible/ansible.cfg
for node in redis-node-4 redis-node-5 redis-node-6; do
  ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/upgrade_node.yml \
    -e "target_host=$node" -e "target_version=7.2.6"
done

# 3. Confirm mixed state: masters v7.0.15, replicas v7.2.6
./redis-tool status

# 4. Roll the replicas back — they re-sync a v10 RDB from the OLD masters → clean
./redis-tool rollback --target-version 7.0.15

# 5. Verify everything is back on the old version with data intact
./redis-tool verify --full --keys 1000 --target-version 7.0.15
```

---

## Design Notes & Limitations

- **Build from source, not apt** — to get the exact requested version. Trade-off: provision/upgrade are
  slower and need internet in the containers.
- **SSH key baked into the image** — the image `COPY`s `infra/id_rsa.pub` into `authorized_keys`, so new
  containers (incl. scaled-out spares) are reachable instantly.
- **Pre-declared spares for scale-out** — 8 containers defined; 6 run by default, node-7/8 (behind a
  compose `profile`) stay off until `scale` starts them. Static IPs `10.10.0.11`–`10.10.0.18`, host SSH
  ports `2201`–`2208`.
- **Cluster commands run from node-1** — all `redis-cli` cluster operations are issued on `redis-node-1`
  over SSH.
- **Downgrade after a *completed* major upgrade is not data-safe** (RDB v11 → v10) — see Rollback Case B.
- **The upgrade replica loop assumes the original 6 nodes.** After `scale --add-nodes 2`, a later
  `upgrade` would need that loop made dynamic to include node-7/8 — a known follow-up.
- **Containers have no systemd** — Redis is started directly with `redis-server /etc/redis/redis.conf`.
- **Containers are ephemeral** — `compose down` destroys installed Redis & data; re-run `provision`.

---

## Project Layout

```
task/
├── redis-tool                 # the CLI (bash): provision/data/status/upgrade/rollback/verify/scale
├── setup.sh                   # one-time host setup (deps, SSH key, build context, hosts.ini)
├── ansible/
│   ├── ansible.cfg            # host_key_checking=False, etc. (redis-tool exports ANSIBLE_CONFIG)
│   ├── inventory/hosts.ini    # 6 active nodes + 2 spares + IPs/ports
│   ├── playbooks/             # provision.yml, provision_node.yml, upgrade_node.yml
│   └── roles/redis/           # install / configure / start / create_cluster / upgrade_install + redis.conf.j2
├── infra/
│   ├── Containerfile          # Ubuntu + SSH image (bakes in id_rsa.pub)
│   ├── id_rsa.pub             # your SSH public key (copied into the build context)
│   └── compose.yml            # 8 nodes on 10.10.0.0/24 (node-7/8 behind "scale" profile)
├── scripts/                   # seed, verify, status, failover, preflight, scale_out, scale_in, wait_cluster_ok, ...
├── logs/                      # logs/redis-tool.jsonl — single JSON-lines operation log (S5)
└── output/                    # saved terminal output of each command
```

---

## Troubleshooting

A brand-new machine exposes things an old box hid (warm DNS, populated `known_hosts`, cached packages).
Common issues and fixes:

| Symptom | Cause | Fix |
|---|---|---|
| `bad interpreter: /bin/bash^M` | Windows CRLF line endings | Linux: `sed -i 's/\r$//' setup.sh redis-tool scripts/*.sh` · macOS/BSD: `sed -i '' 's/\r$//' …` (or `perl -i -pe 's/\r$//' …`) |
| `Permission denied` on `./redis-tool` | not executable | `chmod +x redis-tool scripts/*.sh setup.sh` |
| `podman-compose: command not found` | Podman < 4.1 has no built-in compose | `pip3 install --user podman-compose` (ensure `~/.local/bin` is on `PATH`) |
| `short-name "redis-ssh:latest" did not resolve … no unqualified-search registries` | image/tag missing in the current runtime store (pruned, or rootless/rootful mismatch) | rebuild: `cd infra && podman build -t redis-ssh:latest -f Containerfile .`; if it persists, qualify the name as `localhost/redis-ssh:latest` in `compose.yml` |
| `no container with name "redis-node-7" found` | the create step above failed, so start has nothing to start | fix the image error first |
| `podman ps` empty but `sudo podman ps` shows the nodes | cluster built rootful, command run rootless (or vice versa) | run everything in one context — consistently with or without `sudo` |
| CNI `firewall does not support config version "1.0.0"` (WARN) | old CNI config on rootless Podman 3.4 | harmless warning; ignore, or update CNI plugins |
| `build: id_rsa.pub not found` | key not in build context | `cp ~/.ssh/id_rsa.pub infra/id_rsa.pub` then rebuild |
| `Connection refused` on ports 2201–2208 | containers not running | `cd infra && docker compose up -d` (or `podman-compose up -d`) |
| `Cannot connect to the Docker daemon` | Docker not started | start Docker Desktop / `sudo service docker start` (N/A for rootless Podman) |
| `Host key verification failed` / `ssh_askpass` | `ansible.cfg` not loaded → strict host-key checking | handled: `redis-tool` exports `ANSIBLE_CONFIG`; configs set `StrictHostKeyChecking=no` |
| apt `python3-apt has no installation candidate` / `Failed to fetch archive.ubuntu.com` | containers have no internet | DNS set in `compose.yml` (`8.8.8.8`, `1.1.1.1`); test `docker exec redis-node-1 ping -c1 8.8.8.8` |
| `get_url` 404 for the redis tarball | invalid/partial version string | pass a full, real version (`7.0.15`, `7.2.6`) |
| `redis-cli: command not found` after `compose down`/rebuild | containers are ephemeral; Redis lives only in the container layer | re-run `provision` |
| scale: `DUMP payload version or checksum are wrong` | `add-node` copies Functions (fragile in 7.x) | handled — the tool joins with `CLUSTER MEET` |
| scale-in: "node id not found" for a short id like `7` | not a real node-id | pass the full 40-char id from `status` (see S2) |
| rollback FAILs at the first replica with `Can't handle RDB format version` | all nodes already on the new version (no old master to sync from) | re-provision at the old version + re-seed (see Rollback Case B) |

> **Important — the containers need internet.** This project installs build tools with `apt` and
> downloads the Redis source to compile it, so the containers must have working outbound DNS + HTTP. On a
> locked-down / corporate network you'll need a proxy or an internal mirror.

---

_Built with Bash · Ansible · Redis Cluster · Docker / Podman_
