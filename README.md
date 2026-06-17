# Redis Cluster Lifecycle Tool

A single command-line tool (`redis-tool`) that **builds, operates, upgrades, scales,
and rolls back** a **6-node Redis Cluster** (3 masters + 3 replicas) running inside
Docker/Podman containers. Everything is driven through one CLI — you never SSH in or
type `redis-cli` by hand. The CLI calls **Ansible**, and Ansible does the real work on
the nodes over SSH.

This README is written so that **someone with a brand-new machine can clone the repo
and run the whole thing top to bottom.** Read sections 1–4 in order.

---

## 1. What this project is

The goal is to manage the full lifecycle of a Redis Cluster the way you would in
production, but locally:

- **Provision** a fresh 3-master / 3-replica cluster at an exact Redis version.
- **Seed & verify** 1000 keys with reproducible values to prove data integrity.
- **Report status** — topology, slots, key counts, versions, memory.
- **Rolling upgrade** to a newer version with **zero client-visible downtime**.
- **Full health verification** after the upgrade.
- **Scale out / scale in**, **rollback**, idempotent re-runs, and structured logging.

Three layers do the work:

| Layer | Role |
|-------|------|
| **`redis-tool`** (bash) | The CLI. *Orchestrates only* — parses your command, calls Ansible / helper scripts, logs every step. |
| **Ansible** | Installs Redis (compiled from source for an exact version), writes config, starts Redis, forms the cluster. |
| **Docker / Podman** | 6 (+2 spare) Ubuntu containers that pretend to be remote servers with SSH. |

---

## 2. How the flow goes (the big picture)

```
  YOUR LAPTOP (control node)
  ┌─────────────────────────────────────────────┐
  │  ./redis-tool <command> ...   (bash CLI)      │
  │        │                                      │
  │        │  1. prerequisite check (docker/ansible)
  │        │  2. log_event → logs/redis-tool.jsonl │
  │        ▼                                      │
  │  ansible-playbook  +  helper scripts (run on node-1)
  └────────┬──────────────────────────────────────┘
           │ SSH (host ports 2201–2208 → container :22)
           ▼
  Docker containers = "servers", all on network 10.10.0.0/24
  redis-node-1 (10.10.0.11) ─┐
  redis-node-2 (10.10.0.12)  │  3 masters
  redis-node-3 (10.10.0.13) ─┘
  redis-node-4 (10.10.0.14) ─┐
  redis-node-5 (10.10.0.15)  │  3 replicas
  redis-node-6 (10.10.0.16) ─┘
  redis-node-7 (10.10.0.17)  ┐  spares — OFF by default,
  redis-node-8 (10.10.0.18)  ┘  started only by `scale --add-nodes 2`
```

**Lifecycle order:**

```
setup.sh → docker compose up → provision → data seed → data verify → status
        → upgrade → verify --full        (core task)
        → scale out / scale in / rollback (stretch goals)
```

Every command, in order, runs the prerequisite check first, then writes its actions to
a **single** log file `logs/redis-tool.jsonl`.

---

## 3. One-time setup on a new machine

### 3.1 Prerequisites

The tool checks these on **every** run and stops with install instructions if anything
is missing:

| Tool | Why | Install |
|------|-----|---------|
| Docker **or** Podman (Podman preferred) | Runs the containers | <https://docs.docker.com/engine/install/> · <https://podman.io/docs/installation> |
| Ansible **2.14+** (`ansible-playbook`) | Configures the nodes | `pip install 'ansible>=2.14'` |
| An SSH key at `~/.ssh/id_rsa` | Lets Ansible log into the containers | `ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""` |
| Internet access **inside the containers** | Redis is **compiled from source** (apt + download.redis.io) | corporate networks may need a proxy/mirror |

> The tool builds Redis from source so it gets the *exact* version requested
> (`apt install redis-server` only gives Ubuntu's 6.0.x). This means the containers
> must reach `archive.ubuntu.com` and `download.redis.io`.

### 3.2 Bring the "servers" up

**Easiest — run the setup script.** It checks/installs Docker & Ansible, creates your
SSH key if missing, copies the public key into the build context, and points
`hosts.ini` at your key:

```bash
chmod +x setup.sh
./setup.sh                 # asks before installing; use ./setup.sh --yes to auto-confirm
```

Then build the image (the SSH public key is **baked into the image**, so SSH works the
instant a container starts) and start the 6 nodes:

```bash
cd infra
docker compose up -d --build    # build image + start redis-node-1..6
docker compose ps               # expect 6 containers "Up"
cd ..
cd ansible && ansible redis_nodes -m ping && cd ..   # optional: expect "pong" ×6
```

**Manual equivalent** if you skip `setup.sh`:

```bash
cp ~/.ssh/id_rsa.pub infra/id_rsa.pub        # key into the build context
# edit ansible/inventory/hosts.ini so ansible_ssh_private_key_file → ~/.ssh/id_rsa
```

> If you change your SSH key later, re-copy it to `infra/id_rsa.pub` and rebuild.

---

## 4. Running the project from start (the commands, explained)

Run everything from the project root. Each block says **what it does** and **what a
healthy result looks like**.

### Phase 1 — Provision (build the cluster)
```bash
./redis-tool provision --version 7.0.15 --masters 3 --replicas-per-master 1
```
Downloads & compiles Redis **7.0.15** on all 6 nodes, writes cluster-mode config, starts
Redis, and forms one cluster (3 masters owning slots 0–16383, each with 1 replica).
*Healthy:* ends with the cluster topology printed and `cluster_state:ok`.

### Phase 2 — Seed & verify data
```bash
./redis-tool data seed --keys 1000        # writes 1000 keys across the masters
./redis-tool data verify --keys 1000      # reads them back and recomputes
```
Each value is `SHA256(key name)`, so `verify` recomputes the expected value for every
key — nothing is stored separately. *Healthy:* `PASS — 1000/1000 keys verified`.

### Phase 3 — Status
```bash
./redis-tool status
```
Prints `Cluster State: ok`, then per node: IP, port, role, version, slot range + key
count (masters), which master a replica follows, and memory.

### Phase 4 — Rolling upgrade (the core challenge, zero downtime)
```bash
./redis-tool data verify --keys 1000                          # pre-upgrade baseline
./redis-tool upgrade --target-version 7.2.6 --strategy rolling
```
Upgrades replicas first, then masters via failover (strategy in §5).
*Healthy:* ends with `UPGRADE COMPLETE — all nodes on v7.2.6, data integrity verified`.

### Phase 5 — Full verification
```bash
./redis-tool verify --full --keys 1000 --target-version 7.2.6
```
Five checks, each PASS/FAIL: **data integrity**, **version consistency**, **slot coverage**
(all 16384 covered, every master has a replica), **cluster state ok**, **replication lag**
(`master_link_status:up`).

---

## 4b. Stretch-goal commands

### S1 — Scale out (add a master + replica, rebalance slots)
```bash
./redis-tool scale --add-nodes 2
./redis-tool status        # 10.10.0.17 = new master (owns slots), 10.10.0.18 = its replica
```
Starts the 2 spare containers, installs Redis at the cluster's current version, joins
them with `CLUSTER MEET` (avoids the fragile `add-node` Functions copy), then rebalances
slots so the new master gets its share. The tool now **fails loudly** if the rebalance
never lands slots on the new master (instead of falsely reporting success).

### S2 — Scale in (remove a master + its replica)
```bash
# Needs the FULL 40-char node-id (NOT a short alias like "7"). Capture it first:
NODE_ID=$(ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR -p 2201 redis@127.0.0.1 \
  "redis-cli cluster nodes | awk '\$2 ~ /^10.10.0.17:/ {print \$1}'")
echo "Removing node-id: $NODE_ID"

./redis-tool scale --remove-node "$NODE_ID"
./redis-tool status        # back to 3 masters / 3 replicas, slots redistributed
```
Migrates all slots off the target master (weight 0 rebalance), confirms it owns no
slots (so no data is lost), removes its replica(s) and then the master, and powers off
the freed containers.

> **Why the full node-id matters:** the tool matches the id in field 1 of
> `cluster nodes`. A short value like `7` can word-match unrelated fields (epochs, slot
> numbers) and behave nondeterministically — always pass the real id from `status`/the
> capture above.

### S3 — Rollback (undo a partial/aborted upgrade)
```bash
./redis-tool rollback --target-version 7.0.15
```
Downgrades any node **ahead of** the target version (nodes already at the target are
skipped). Each rolled-back node is **wiped and re-syncs clean from its master.**
**This only works while old-version masters are still alive** — see §7 for the full
explanation and a test procedure.

---

## 5. The rolling upgrade strategy (and why)

The cluster must stay `cluster_state:ok` the entire time. The order is what makes it safe:

1. **Pre-flight** — cluster healthy? all nodes reachable? current version ≠ target?
   data baseline OK? If any fail, stop before touching anything. (If everything is
   already on the target, it prints "nothing to do" and exits — see S4 idempotency.)
2. **Upgrade replicas first, one at a time** — a replica serves no slots, so taking one
   down loses neither data nor availability. Wait for `cluster:ok` after each.
3. **Upgrade masters with failover** — for each master, run `CLUSTER FAILOVER` on its
   *already-upgraded* replica so the replica becomes master (traffic moves to the new
   version), then upgrade the old master (now a replica) safely.
4. **Post-upgrade verification** — `data verify` + `status` prove zero data loss.

> One-line reason: **never take down a serving master before a newer replica has taken
> its place.**

---

## 6. How the exact version gets installed (and what can go wrong)

Both provision and upgrade run the same install logic
(`roles/redis/tasks/install.yml`, `upgrade_install.yml`):

1. Install build deps (`build-essential`, `tcl`, `wget`, …) via apt.
2. Remove any apt-installed Redis (so the wrong version can't shadow ours in `/usr/bin`).
3. **Download `https://download.redis.io/releases/redis-<version>.tar.gz`** and compile
   it into `/usr/local` — but only if the running binary isn't already that version.
4. **Assert** the installed binary reports the requested version, or fail the play.

**Things that bite you here:**

| Symptom | Cause | Fix |
|---|---|---|
| `get_url` 404 / "Could not download" | the version string doesn't exist at download.redis.io (typo, or `7.2` instead of the full `7.2.6`) | always pass a **full, real** version like `7.0.15` / `7.2.6` |
| Install seems to "skip" and the assert still passes with the wrong binary | the version check is a **substring** match — e.g. asking for `7.0.1` when `7.0.15` is installed: `7.0.1` *is* a substring of `7.0.15`, so it thinks it's already installed | use exact patch versions that aren't prefixes of each other; verify with `./redis-tool status` |
| First provision/upgrade is slow | source compile (`make -j`) on every node | expected — subsequent runs reuse the binary |
| Compile fails / apt fails | container can't reach the internet | see the network note in §3.1 and the troubleshooting table |

---

## 7. Rollback in depth (the case you'll hit)

Rollback's whole mechanism is: **stop the node → install the old version → wipe its data
files → restart → let it re-sync fresh from its master.** It wipes the data on purpose,
because an older Redis cannot read the newer on-disk RDB. The data is preserved because
the node pulls a fresh copy from its master.

That last part is the catch: **the master it syncs from must be on the old version.**

- **Redis 7.0 writes RDB v10. Redis 7.2 writes RDB v11. A 7.0 instance cannot load a
  v11 RDB.**

### Case A — partial / aborted upgrade (rollback works) ✅
Masters still on 7.0.15, replicas already bumped to 7.2.6. Rolling back the replicas
downgrades them to 7.0.15 and they full-sync a **v10** RDB from the still-7.0.15
masters → success. **This is exactly what rollback is built for.**

### Case B — every node already on the new version (rollback can't preserve data) ❌
If you already ran a *complete* upgrade and all 6 nodes are on 7.2.6, then run
`rollback --target-version 7.0.15`:

- `cmd_rollback` has **no "everything is newer, nothing to do" guard** (unlike `upgrade`).
  Since no node is *at* 7.0.15, none are skipped — it tries to downgrade all six.
- The first replica is downgraded to 7.0.15, wiped, restarted, and full-syncs from its
  master — which is **still 7.2.6**, so it receives a **v11** RDB. The 7.0.15 replica
  rejects it (`Can't handle RDB format version 11`), the sync never completes,
  `wait_cluster_ok` times out, and rollback prints **FAIL at that node.**

**Takeaway:** rollback is for aborting a *partial* upgrade, not for downgrading a fully
upgraded cluster. To return a fully-upgraded cluster to the old version you must
re-provision at the old version and re-seed:
```bash
./redis-tool provision --version 7.0.15 --masters 3 --replicas-per-master 1
./redis-tool data seed --keys 1000
```

### Test S3 the way it's designed (force the partial-upgrade state)
The CLI only does *full* upgrades, so simulate an upgrade interrupted after the
replica phase by upgrading **only the replicas** via the playbook:

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

# 4. Roll the replicas back — they re-sync v10 RDB from the OLD masters → clean
./redis-tool rollback --target-version 7.0.15

# 5. Verify everything is back on the old version with data intact
./redis-tool verify --full --keys 1000 --target-version 7.0.15
```

---

## 8. Stretch goals implemented

- **S1 — Scale out:** `scale --add-nodes 2` adds a master + replica from the 2 spare
  containers and rebalances slots, live; fails loudly if slots don't land.
- **S2 — Scale in:** `scale --remove-node <node-id>` migrates slots off a master,
  removes it + its replica, and stops the freed containers.
- **S3 — Rollback:** `rollback --target-version <old>` undoes a partial/aborted upgrade
  (see §7 for the data-safety boundary).
- **S4 — Idempotency:** re-running `provision` on a healthy cluster is a no-op; running
  `upgrade` when every node is already on the target prints "nothing to do" and exits
  cleanly with no failover.
- **S5 — Structured logging:** every command appends JSON-lines to a **single** file
  `logs/redis-tool.jsonl` (timestamp, command, node, action, outcome).

### Reading the log
```bash
cat logs/redis-tool.jsonl          # full history, all commands, one file
tail -f logs/redis-tool.jsonl      # follow live during a run
```

---

## 9. Assumptions & trade-offs

- **Build from source, not apt** — to get the exact requested version (apt gives 6.0.x).
  Trade-off: provision/upgrade are slower and need internet in the containers.
- **SSH key baked into the image** — the image `COPY`s `infra/id_rsa.pub` into
  `authorized_keys`, so new containers (incl. scaled-out spares) are reachable instantly.
- **Pre-declared spares for scale-out** — 8 containers defined; 6 run by default, node-7/8
  (behind a compose `profile`) stay off until `scale` starts them. Static IPs
  `10.10.0.11`–`10.10.0.18`, host SSH ports `2201`–`2208`.
- **Cluster commands run from node-1** — all `redis-cli` cluster operations are issued on
  `redis-node-1` over SSH.

---

## 10. Known limitations

- **Downgrade after a *completed* major upgrade is not data-safe** (RDB v11 → v10). See
  §7 Case B. Rollback targets *partial* upgrades only.
- **The upgrade replica loop assumes the original 6 nodes.** After a `scale --add-nodes 2`,
  a later `upgrade` would need that loop made dynamic to include node-7/8 — a known
  follow-up.
- **Containers have no systemd** — Redis is started directly with
  `redis-server /etc/redis/redis.conf`, not `systemctl`.
- **Containers are ephemeral** — `docker compose down` destroys installed Redis & data;
  re-run `provision` to rebuild.

---

## 11. Project layout

```
task/
├── redis-tool                 # the CLI (bash): provision/data/status/upgrade/rollback/verify/scale
├── setup.sh                   # one-time host setup (deps, SSH key, build context, hosts.ini)
├── ansible/
│   ├── ansible.cfg            # host_key_checking=False etc. (redis-tool exports ANSIBLE_CONFIG)
│   ├── inventory/hosts.ini     # 6 active nodes + 2 spares + IPs/ports
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

## 12. Troubleshooting (especially on a fresh machine)

A brand-new machine exposes things an old box hid (warm DNS, populated `known_hosts`,
cached packages). Common issues and fixes:

| Symptom | Cause | Fix |
|---|---|---|
| `bad interpreter: /bin/bash^M` | Windows CRLF line endings | `sed -i 's/\r$//' setup.sh redis-tool scripts/*.sh` |
| `Permission denied` on `./redis-tool` | not executable | `chmod +x redis-tool scripts/*.sh setup.sh` |
| `build: id_rsa.pub not found` | key not in build context | `cp ~/.ssh/id_rsa.pub infra/id_rsa.pub` then rebuild |
| `Connection refused` on ports 2201–2208 | containers not running | `cd infra && docker compose up -d` |
| `Cannot connect to the Docker daemon` | Docker not started | start Docker Desktop / `sudo service docker start` |
| `Host key verification failed` / `ssh_askpass` | `ansible.cfg` not loaded → strict host-key checking | handled: `redis-tool` exports `ANSIBLE_CONFIG`, configs set `StrictHostKeyChecking=no` |
| apt `python3-apt has no installation candidate` / `Failed to fetch archive.ubuntu.com` | containers have no internet | DNS set in `compose.yml` (`8.8.8.8`, `1.1.1.1`); test `docker exec redis-node-1 ping -c1 8.8.8.8` |
| `get_url` 404 for redis tarball | invalid/partial version string | pass a full real version (`7.0.15`, `7.2.6`) — see §6 |
| `redis-cli: command not found` after `compose down`/rebuild | containers are ephemeral; Redis lives only in the container layer | re-run `provision` |
| scale: `DUMP payload version or checksum are wrong` | `add-node` copies Functions (fragile in 7.x) | handled — tool joins with `CLUSTER MEET` |
| scale-in: "node id not found" for a short id like `7` | not a real node-id | pass the full 40-char id from `status` (see S2) |
| rollback fails at the first replica with `Can't handle RDB format version` | all nodes already on the new version (no old master to sync from) | re-provision at the old version + re-seed — see §7 Case B |

> **Important — the containers need internet.** This project installs build tools with
> `apt` and downloads the Redis source to compile it, so the containers must have working
> outbound DNS + HTTP. On a locked-down/corporate network you'll need a proxy or mirror.
