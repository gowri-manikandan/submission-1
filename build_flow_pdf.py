# -*- coding: utf-8 -*-
"""Generate the project flow + interview PDF for the Redis Cluster Lifecycle Tool."""
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (SimpleDocTemplate, Paragraph, Spacer, Table,
                                TableStyle, PageBreak, ListFlowable, ListItem)

FONT, FONT_B, MONO = "Helvetica", "Helvetica-Bold", "Courier"
try:
    pdfmetrics.registerFont(TTFont("Body", r"C:\Windows\Fonts\arial.ttf"))
    pdfmetrics.registerFont(TTFont("Body-B", r"C:\Windows\Fonts\arialbd.ttf"))
    FONT, FONT_B = "Body", "Body-B"
except Exception:
    pass
for cand in (r"C:\Windows\Fonts\consola.ttf", r"C:\Windows\Fonts\cour.ttf"):
    try:
        pdfmetrics.registerFont(TTFont("Mono", cand)); MONO = "Mono"; break
    except Exception:
        pass

RED = colors.HexColor("#A6271E"); DARK = colors.HexColor("#1F2933")
GREY = colors.HexColor("#52606D"); LIGHT = colors.HexColor("#F0F2F5")
CODEBG = colors.HexColor("#F5F3EF")
styles = getSampleStyleSheet()
def S(name, **kw):
    base = kw.pop("parent", styles["Normal"]); return ParagraphStyle(name, parent=base, **kw)
title_s = S("t", fontName=FONT_B, fontSize=24, textColor=RED, leading=28, spaceAfter=6)
sub_s   = S("s", fontName=FONT, fontSize=12, textColor=GREY, leading=16, spaceAfter=2)
h1_s    = S("h1", fontName=FONT_B, fontSize=16, textColor=RED, leading=20, spaceBefore=14, spaceAfter=6)
h2_s    = S("h2", fontName=FONT_B, fontSize=12.5, textColor=DARK, leading=16, spaceBefore=10, spaceAfter=4)
h3_s    = S("h3", fontName=FONT_B, fontSize=11, textColor=GREY, leading=14, spaceBefore=6, spaceAfter=2)
body_s  = S("b", fontName=FONT, fontSize=10, textColor=DARK, leading=14.5, spaceAfter=5)
bullet_s= S("bl", fontName=FONT, fontSize=10, textColor=DARK, leading=14, spaceAfter=2)
code_s  = S("c", fontName=MONO, fontSize=8.2, textColor=DARK, leading=11, backColor=CODEBG, borderPadding=6, spaceBefore=3, spaceAfter=7)
quote_s = S("q", fontName=FONT, fontSize=9.6, textColor=RED, leading=14, leftIndent=8, spaceAfter=6)
cell_s  = S("cell", fontName=FONT, fontSize=8.6, textColor=DARK, leading=11)
cellb_s = S("cellb", fontName=FONT_B, fontSize=8.6, textColor=colors.white, leading=11)

story = []
def P(t, st=body_s): story.append(Paragraph(t, st))
def H1(t): story.append(Paragraph(t, h1_s))
def H2(t): story.append(Paragraph(t, h2_s))
def H3(t): story.append(Paragraph(t, h3_s))
def SP(h=4): story.append(Spacer(1, h))
def CODE(t):
    safe = t.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace("\n","<br/>")
    story.append(Paragraph(safe, code_s))
def QUOTE(t): story.append(Paragraph('"' + t + '"', quote_s))
def BULLETS(items):
    fl = [ListItem(Paragraph(x, bullet_s), leftIndent=6) for x in items]
    story.append(ListFlowable(fl, bulletType="bullet", start="•", leftIndent=12)); SP(4)
def TABLE(headers, rows, widths):
    data = [[Paragraph(h, cellb_s) for h in headers]]
    for r in rows: data.append([Paragraph(str(c), cell_s) for c in r])
    t = Table(data, colWidths=widths, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND",(0,0),(-1,0),RED),
        ("ROWBACKGROUNDS",(0,1),(-1,-1),[colors.white,LIGHT]),
        ("GRID",(0,0),(-1,-1),0.4,colors.HexColor("#CBD2D9")),
        ("VALIGN",(0,0),(-1,-1),"TOP"),
        ("LEFTPADDING",(0,0),(-1,-1),5),("RIGHTPADDING",(0,0),(-1,-1),5),
        ("TOPPADDING",(0,0),(-1,-1),3),("BOTTOMPADDING",(0,0),(-1,-1),3),
    ]))
    story.append(t); SP(8)

# ===== TITLE =====
P("Redis Cluster Lifecycle Tool", title_s)
P("Build Flow, Bugs &amp; Fixes, and Interview Notes", sub_s)
P("A bash CLI (<b>redis-tool</b>) that orchestrates Ansible to provision, operate, upgrade, "
  "scale, and roll back a Redis Cluster running in Docker containers.", sub_s)
SP(10)
TABLE(["Capability", "Command", "Status"], [
    ["1 - Provision", "provision --version 7.0.15 --masters 3 --replicas-per-master 1", "Done"],
    ["2 - Data seed / verify", "data seed | data verify", "Done"],
    ["3 - Status", "status", "Done"],
    ["4 - Rolling upgrade", "upgrade --target-version 7.2.6 --strategy rolling", "Done"],
    ["5 - Full verify", "verify --full", "Done"],
    ["S1 - Scale out", "scale --add-nodes 2", "Done"],
    ["S3 - Rollback (partial)", "rollback --target-version 7.0.15", "Done"],
    ["S4 - Idempotency", "re-run provision/upgrade safely", "Done"],
    ["S5 - Structured logging", "JSON logs in logs/", "Done"],
    ["SSH key baked into image", "build-time COPY of id_rsa.pub", "Done"],
    ["S2 - Scale in", "reshard + del-node", "Not built (assessed)"],
], [150, 250, 70])

# ===== 1. ARCHITECTURE =====
H1("1. How the pieces fit together")
P("The host laptop is the <b>Ansible control node</b>. Docker containers act as remote servers "
  "reachable over SSH. The CLI never touches Redis directly - it calls Ansible, and Ansible runs "
  "tasks on the nodes.")
CODE("YOUR LAPTOP (control node)\n"
     "  ./redis-tool  (bash CLI)\n"
     "        |  ansible-playbook over SSH (ports 2201-2208)\n"
     "        v\n"
     "  8 containers defined; 6 active + 2 spare (for scale-out)\n"
     "  redis-node-1..6  IPs 10.10.0.11 .. 10.10.0.16   (active)\n"
     "  redis-node-7,8   IPs 10.10.0.17 .. 10.10.0.18   (spare, off by default)\n"
     "        -> one Redis Cluster: 3 masters + 3 replicas")
TABLE(["Layer", "Tool", "Job"], [
    ["CLI / orchestration", "redis-tool (bash)", "Parse commands, call playbooks, gate on health, log"],
    ["Automation", "Ansible", "Install Redis, write config, start, form cluster, upgrade, rollback"],
    ["Infrastructure", "Docker Compose", "8 Ubuntu+SSH containers on a static 10.10.0.0/24 network"],
    ["Cluster commands", "redis-cli on node-1", "cluster info/nodes, failover, MEET, rebalance, seed/verify"],
], [110, 120, 240])

# ===== 2. BUILD FLOW =====
H1("2. The build flow, step by step")
P("Built incrementally; each step tested before the next. Every command runs one or more "
  "Ansible playbooks.")
BULLETS([
    "<b>CLI skeleton</b> - main() + subcommands; a prerequisite check (Docker/Podman + Ansible 2.14+) runs first on every command.",
    "<b>Infrastructure</b> - build image, start 6 containers; SSH key reaches them (now baked into the image).",
    "<b>Install + configure + start</b> - Ansible builds Redis from source into /usr/local/bin and starts it.",
    "<b>Static IPs</b> - fixed 10.10.0.x so the cluster has stable addresses.",
    "<b>Form cluster</b> - redis-cli --cluster create: 3 masters + 3 replicas, 16384 slots.",
    "<b>Seed/verify</b> - value = SHA256(key); verify recomputes and compares (proves zero data loss).",
    "<b>Status</b> - prints masters (slots/keys), replicas (who they follow), versions, memory.",
    "<b>Rolling upgrade</b> - pre-flight, replicas first, masters via CLUSTER FAILOVER, post-verify.",
    "<b>verify --full</b> - 5 checks: data, version, slots, cluster state, replication.",
])

H2("Rolling upgrade strategy (and why)")
BULLETS([
    "<b>Pre-flight:</b> cluster ok? nodes reachable? version differs? data baseline ok? - else stop.",
    "<b>Replicas first</b> (one at a time): a replica owns no slots, so taking it down costs nothing.",
    "<b>Masters with failover:</b> CLUSTER FAILOVER promotes the upgraded replica, then the old master upgrades as a replica.",
    "<b>Post-verify:</b> data verify + status -> UPGRADE COMPLETE.",
])
QUOTE("Never take down a serving master before a newer replica has taken its place.")

# ===== 3. BUGS & FIXES =====
PageBreak()
H1("3. Bugs encountered &amp; how they were fixed")
H2("A. During the initial build (Phases 1-5)")
TABLE(["Symptom", "Root cause", "Fix"], [
    ["YAML parse error in provision.yml", "Bash pasted into a YAML file", "Keep bash in redis-tool, YAML in playbooks"],
    ["'Service is in unknown state'", "Containers have no systemd", "Start redis-server directly, not the service module"],
    ["compose 'did not find - indicator'", "networks: nested under ports:", "networks: at the same indent as ports:"],
    ["ip addr -> no output", "iproute2 not in image", "Use docker inspect / ifconfig"],
    ["cluster_state:fail", "Redis announced 127.0.0.1 in Docker", "cluster-announce-ip per node; reset & re-form"],
    ["Masters were 6.0.16 not 7.0.15", "apt ignored --version", "Build exact version from source; /usr/local/bin"],
    ["/etc/redis does not exist", "Removed apt pkg that made the dir", "Create /etc/redis before templating config"],
    ["Version stayed 7.0.15 after upgrade", "Ansible 'creates:' skipped rebuild", "Rebuild when target version not installed"],
    ["verify_full.sh not found", "Filename typo (verfiy)", "Rename to verify_full.sh"],
], [150, 150, 190])
H2("B. Parsing bugs (the 'myself,' family)")
P("These break only once node-1 (where redis-cli runs) changes role - its own row in "
  "<font name='%s'>cluster nodes</font> is tagged <font name='%s'>myself,slave</font>." % (MONO, MONO))
TABLE(["File / symptom", "Root cause", "Fix"], [
    ["create_cluster.yml parse error", "delegate_to over-indented", "Align with other task keys"],
    ["status: a replica missing", "exact == \"slave\" missed myself,slave", "Wildcard != *slave*"],
    ["verify_full topology FALSE fail", "$3 == \"slave\" missed node-1", "$3 ~ /slave/"],
    ["verify_full garbled version", "tr -d '[:space:]' ate newlines", "tr -d '\\t\\r' (keep newline)"],
    ["verify_full version FALSE fail", "CRLF: Redis INFO ends with \\r", "strip \\r before compare"],
], [175, 165, 150])

# ===== 4. THE THREE ADD-ON FEATURES (with debugging) =====
PageBreak()
H1("4. Add-on features &amp; their debugging stories")
P("Three capabilities added after the core, each with real debugging worth describing in an interview.")

H2("Feature 1 - SSH key baked into the image")
P("The Containerfile now COPYs <font name='%s'>infra/id_rsa.pub</font> into authorized_keys at "
  "build time, so containers are reachable the moment they start - no bootstrap step." % MONO)
TABLE(["Issue hit", "Cause", "Fix"], [
    ["build: '/id_rsa.pub not found'", "COPY can only read the build context; key was in ~/.ssh", "cp ~/.ssh/id_rsa.pub infra/ then build"],
    ["redis-cli: command not found later", "docker compose down recreated containers; Redis (installed at runtime) was wiped", "Re-provision; containers are ephemeral - data/Redis live only in the writable layer"],
], [150, 200, 140])
P("<b>Trade-off:</b> baking the key makes the image personal; the alternative (runtime bootstrap) "
  "keeps it generic. Chosen build-time for instant reachability of scaled-out spares.")

H2("Feature 2 - Scale out (S1)")
P("<font name='%s'>scale --add-nodes 2</font>: start 2 spare containers (compose profile), install "
  "Redis at the cluster's version, join via CLUSTER MEET + REPLICATE, then rebalance slots." % MONO)
TABLE(["Issue hit", "Cause", "Fix"], [
    ["add-node: 'DUMP payload version or checksum are wrong'", "redis-cli add-node copies Functions (FUNCTION DUMP/RESTORE), fragile in 7.x", "Join with CLUSTER MEET + CLUSTER REPLICATE - no function copy"],
    ["new master stuck on v7.0.15; rebalance CLUSTERDOWN", "A leftover 7.0.15 was already running, so start.yml skipped the restart of the new 7.2.6 binary", "provision_node now stops Redis first, so the new binary always runs"],
    ["rebalance: 'slots in migrating state'", "Earlier rebalance died mid-move, leaving an open slot", "redis-cli --cluster fix before rebalance (now built in)"],
], [150, 200, 140])

H2("Feature 3 - Rollback (S3, partial)")
P("<font name='%s'>rollback --target-version 7.0.15</font>: downgrade nodes ahead of the target; "
  "each is wiped and re-syncs clean from a surviving old-version master." % MONO)
TABLE(["Issue hit", "Cause", "Fix / decision"], [
    ["Downgraded node died on start ('Connection refused')", "Redis 7.2 writes RDB v11; 7.0 can't read it", "Wipe the data dir on downgrade (keep nodes.conf) so the node re-syncs clean"],
    ["A full downgrade still can't keep data", "While any master is 7.2, it ships v11 on resync", "Scope rollback to a PARTIAL/aborted upgrade (old masters still alive); document the rest"],
], [165, 175, 150])
QUOTE("Rollback isn't a tooling problem - it's a data-format constraint. RDB versions aren't "
      "backward-compatible, so I roll back only while an old-version master survives to re-sync from.")

# ===== 5. STRETCH GOALS SUMMARY + ROBUSTNESS =====
H1("5. Stretch goals &amp; robustness")
TABLE(["Goal", "Status", "Note"], [
    ["S1 Scale out", "Done", "add master+replica via MEET, rebalance slots"],
    ["S2 Scale in", "Assessed", "reshard off a master then del-node; not built"],
    ["S3 Rollback", "Done (partial)", "wipe + re-sync; full downgrade documented as impossible online"],
    ["S4 Idempotency", "Done", "re-run provision/upgrade safely; all-nodes version pre-check"],
    ["S5 Logging", "Done", "JSONL per command: ts, node, action, outcome"],
], [95, 95, 300])
P("<b>Spec/robustness fixes:</b> enforce Ansible 2.14+ (sort -V compare); Podman-agnostic "
  "bootstrap; safe IP matching with grep -F -w; per-node failure logging; status guards empty slots.")

H2("Portability - making it run on a fresh machine")
P("A new box exposed things the original masked (warm DNS, a populated known_hosts, cached "
  "packages). A setup.sh script automates the rest (deps, SSH key, build-context copy, hosts.ini path).")
TABLE(["Fresh-machine failure", "Cause", "Fix"], [
    ["Host key verification failed / ssh_askpass missing", "ansible.cfg not loaded from project root, so host-key checking defaulted to strict", "redis-tool exports ANSIBLE_CONFIG; ansible.cfg + hosts.ini set StrictHostKeyChecking=no"],
    ["apt: python3-apt has no candidate / can't fetch archive.ubuntu.com", "containers had no working DNS / outbound", "DNS (8.8.8.8/1.1.1.1) added in compose; python3-apt + build deps baked into the image"],
    ["redis-cli: command not found after a rebuild", "containers are ephemeral; Redis is installed at runtime", "re-provision; documented that data/Redis live only in the container layer"],
], [165, 165, 160])
P("<b>Key realization:</b> the containers must have internet (they apt-install build tools and "
  "download Redis source to compile). On a locked-down network that needs a proxy or mirror.")

# ===== 6. INTERVIEW POINTS =====
PageBreak()
H1("6. Interview talking points")
H2("30-second pitch")
QUOTE("I built a bash CLI, redis-tool, that orchestrates Ansible to manage a Redis cluster in "
      "Docker. I provision exact versions from source, seed deterministic SHA256 data, run a "
      "rolling upgrade (replicas first, masters via CLUSTER FAILOVER), scale out with MEET + "
      "rebalance, and roll back a partial upgrade - verifying integrity throughout.")
H2("Rolling upgrade")
QUOTE("Replicas first because they own no slots; for masters I failover to an already-upgraded "
      "replica so traffic moves to the new version before I stop the old master. Zero downtime.")
H2("Scale-out")
QUOTE("redis-cli add-node copies Functions and fails with a DUMP-checksum error in 7.x, so I join "
      "nodes with CLUSTER MEET + CLUSTER REPLICATE and then rebalance. I also learned to restart a "
      "node after installing a new binary - otherwise an old process keeps serving the old version.")
H2("Rollback &amp; knowing the limits")
QUOTE("Redis 7.0 can't read 7.2's RDB v11, so a full online downgrade can't preserve data. I scope "
      "rollback to aborting a partial upgrade, where the rolled-back node re-syncs from a surviving "
      "old-version master, and I document the rest instead of shipping silent data loss.")
H2("Debugging discipline")
QUOTE("Two lessons recur: don't mix bash into YAML, and never match cluster roles with exact "
      "strings - the node you query tags its own row 'myself,role', so I use wildcards everywhere.")
H2("Idempotency &amp; observability")
QUOTE("Re-running provision or upgrade is a safe no-op, and every command writes a JSON operation "
      "log with timestamps, node, action and outcome - so any run is auditable afterward.")
H2("Portability")
QUOTE("Moving to a fresh machine surfaced hidden assumptions - Ansible wasn't loading my config "
      "from the project root so host-key checking blocked SSH, and the containers had no DNS to "
      "reach apt mirrors. I exported ANSIBLE_CONFIG, set DNS in compose, baked build deps into the "
      "image, and wrote a setup.sh - so the project bootstraps itself on any clean box.")

# ===== 7. RUN / SUBMISSION =====
H1("7. Running it")
P("One-time setup (setup.sh handles deps, SSH key, build-context copy, hosts.ini path):")
CODE("./setup.sh --yes\n"
     "cd infra && docker compose up -d --build && cd ..")
P("Core phases:")
CODE("./redis-tool provision --version 7.0.15 --masters 3 --replicas-per-master 1\n"
     "./redis-tool data seed --keys 1000\n"
     "./redis-tool status\n"
     "./redis-tool upgrade --target-version 7.2.6 --strategy rolling\n"
     "./redis-tool verify --full --keys 1000 --target-version 7.2.6")
P("Stretch:")
CODE("./redis-tool scale --add-nodes 2          # add a master+replica, rebalance\n"
     "./redis-tool rollback --target-version 7.0.15   # undo a partial upgrade")

OUT = r"C:\MGM\DevOps\task\Redis_Cluster_Tool_Flow.pdf"
def footer(canvas, doc):
    canvas.saveState(); canvas.setFont(FONT, 8); canvas.setFillColor(GREY)
    canvas.drawString(18*mm, 12*mm, "Redis Cluster Lifecycle Tool - Flow & Interview Notes")
    canvas.drawRightString(A4[0]-18*mm, 12*mm, "Page %d" % doc.page)
    canvas.restoreState()
doc = SimpleDocTemplate(OUT, pagesize=A4, leftMargin=18*mm, rightMargin=18*mm,
                        topMargin=16*mm, bottomMargin=18*mm,
                        title="Redis Cluster Lifecycle Tool - Flow & Interview Notes")
doc.build(story, onFirstPage=footer, onLaterPages=footer)
print("WROTE", OUT)
