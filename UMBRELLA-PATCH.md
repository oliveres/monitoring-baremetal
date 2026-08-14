# Wiring into monitoring-stack

Steps to register this component in the umbrella repo.

## 1. Create the repo and add as submodule

```bash
# in monitoring-stack/
git submodule add https://github.com/oliveres/monitoring-baremetal.git baremetal
git commit -m "Add monitoring-baremetal submodule"
```

Resulting `.gitmodules` entry:

```ini
[submodule "baremetal"]
	path = baremetal
	url = https://github.com/oliveres/monitoring-baremetal.git
```

## 2. README.md changes

Under **Repository Structure**, add:

```markdown
- **[monitoring-baremetal](baremetal)** - **Native agent** for physical servers and
  hypervisors that are not Docker hosts (Proxmox, bare-metal). Installs via systemd,
  adds IPMI sensor collection.
```

Under **Components**, the diagram gains a third edge type:

```
┌───────────────────────────────────────────────────────────┐
│  Central Server (DigitalOcean Droplet)                    │
│  ┌──────────┐  ┌────────────┐  ┌──────┐  ┌───────┐       │
│  │ Grafana  │  │ Prometheus │  │ Loki │  │ Caddy │       │
│  └──────────┘  └────────────┘  └──────┘  └───────┘       │
└───────┬───────────────────────────────────────┬───────────┘
        │  remote write / push                  │
┌───────┴────────────────────┐   ┌──────────────┴────────────┐
│  Edge Hosts (Docker)       │   │  Bare Metal (hypervisors) │
│  Prom Agent / Promtail     │   │  Prom Agent / Promtail    │
│  cAdvisor / node-exporter  │   │  node-exporter / IPMI     │
│  [Docker Compose]          │   │  pve-exporter [systemd]   │
└────────────────────────────┘   └───────────────────────────┘
```

Under **Monitoring Targets**, add:

```markdown
- Physical server health (IPMI: temperatures, fan RPM, voltages, chassis intrusion)
- Proxmox VE guests, storage and cluster quorum (PVE Exporter)
```

Under **Requirements**, note that the bare-metal component needs neither Docker nor
Portainer - it is a systemd install and is deliberately not deployed via GitOps,
because a hypervisor agent should not depend on a container runtime that may be down.

## 3. Central server changes (monitoring-grafana)

```bash
cp baremetal/dashboards/hypervisor-baremetal.json \
   grafana/provisioning/dashboards/

cp baremetal/dashboards/alerts-baremetal.yml \
   grafana/prometheus/rules/
```

Check that the central `prometheus.yml` has `rule_files` pointing at that directory;
if the central stack currently has no rules loaded, this will be the first entry and
the glob needs adding.

## 4. Caddy

No change needed. The bare-metal agent uses the same
`/prometheus/api/v1/write` and `/loki/api/v1/push` endpoints with the same basic auth
credentials as the Docker edge hosts.

Worth confirming the basic-auth user is shared intentionally rather than per-host - if
you ever want to revoke one edge host, per-host credentials make that possible without
re-deploying every agent.
