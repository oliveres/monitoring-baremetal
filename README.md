# Monitoring Baremetal

Native edge agent for **physical servers and hypervisors** that are not Docker hosts.
Part of the [monitoring-stack](https://github.com/oliveres/monitoring-stack) family,
alongside `monitoring-edge` (Docker hosts) and `monitoring-grafana` (central server).

Built and tested against a Supermicro **SYS-510D-4C-FN6P** (X12SDV-4C-SP6F, AST2600 BMC)
running **Proxmox VE 9**.

## Why not monitoring-edge?

`monitoring-edge` assumes a Docker host. On a hypervisor that breaks in three ways:

| Component | Problem on a hypervisor |
|---|---|
| `node-exporter` (container) | Reports the container's view, not the host's. `hwmon` and `powercap` are not exposed at all. |
| `cAdvisor` | Nothing to watch - the host runs VMs and LXC, not containers. |
| `ipmi_exporter` | Needs `/dev/ipmi0`, a char device on the host. Unavailable in unprivileged LXC; requires a privileged container otherwise. |

Running the stack in a VM *on the monitored hypervisor* would also create a circular
dependency: when the host degrades, the VM degrades, and telemetry disappears exactly
when it is needed. So this component installs natively with systemd units.

## What it collects

```
Supermicro host
├── prometheus-node-exporter  :9100   CPU, RAM, disk, network, RAPL, coretemp
├── ipmi_exporter             :9290   BMC sensors over local KCS (/dev/ipmi0)
├── pve-exporter              :9221   Proxmox API - guests, storage, quorum   [optional]
├── promtail                  :9080   journald -> central Loki                [optional]
└── prometheus --agent        :9090   scrapes the above, remote-writes out
                                        │
                                        ▼  HTTPS + Basic Auth via Caddy
                              central Prometheus / Loki
```

Metrics arrive labelled `host=<HOSTNAME>`, `role=hypervisor`, so they sit alongside the
Docker edge hosts in the same Grafana without collision.

## Install

```bash
git clone https://github.com/oliveres/monitoring-baremetal
cd monitoring-baremetal
cp .env.example .env
$EDITOR .env
sudo ./install.sh
```

The installer resolves the latest upstream release for each binary at install time
rather than pinning versions, verifies `/dev/ipmi0` before doing anything, and prints
a metric count per exporter at the end.

Then on the **central** server:

- copy `dashboards/hypervisor-baremetal.json` into `monitoring-grafana/provisioning/dashboards/`
- copy `dashboards/alerts-baremetal.yml` into the central Prometheus rules directory

Agent mode has rule evaluation disabled, so alerts must live centrally.

## Notes from the reference deployment

**Scrape interval.** `monitoring-edge` uses `scrape_interval: 5s` globally. The IPMI job
here is pinned to **30s** and should stay there - the AST2600 BMC degrades under faster
SDR polling and starts timing out. Temperatures do not move faster than that anyway.

**No power metrics.** This board has no platform power sensor. Everything was tried:

| Source | Result |
|---|---|
| PMBus PSU | No such hardware in the CSE-505 chassis |
| DCMI | `Power reading state is: deactivated`; activation returns `0xd5` |
| Intel Node Manager | ACPI object present, `_PMM` returns `0xFFFFFFFF`; raw `0x2e 0xc8` returns `0xc1` |
| RAPL | **Works** - `package-0` + `dram` only |

The dashboard shows RAPL and labels it as such. It covers roughly half of real draw;
chipset, NICs, fans and PSU losses are invisible. For true consumption, measure at the
wall and push that series in separately rather than adding a fudge constant to RAPL -
a hardcoded offset in a recording rule becomes unreadable within a year.

**Fan speeds look alarming and are not.** 40mm fans in this chassis run ~16000 RPM at
Full Speed, so the ~7500 RPM seen in Optimal mode is about half range. Do not set a
manual duty cycle: the BMC overrides it on any thermal excursion, and a 4-core SoC in a
sealed 1U has no thermal headroom to trade for quiet.

**Excluded sensors.** `ipmi/ipmi_exporter.yml` drops FAN3, FAN4, FANB and M2_SSD1 Temp -
headers not populated on this board, reported as `No Reading`, and they arrive as NaN.
Re-check the IDs against `ipmi-sensors --list` on any other model.

**Alert on `ipmi_sensor_state`,** not on individual rails. One rule covers ~30 sensors
including voltages and chassis intrusion; thresholding each is not worth the maintenance.

## Differences from the edge agent config

- no `write_relabel_configs` host override - `external_labels` already carries the label,
  and forcing it per-sample would clobber labels if a remote target is ever added
- optional jobs use the same `regex: '^$'` / `action: drop` convention as `monitoring-edge`,
  so unset env vars silently disable their scrape job
- promtail reads journald instead of `/var/lib/docker/containers`

## Known issues

Found on 23 Oct 2026 while reviewing this repo; not fixed yet, to be investigated
later. They affect any host this agent is deployed on.

1. **Sensor alerts miss most sensors.** The rules in `dashboards/alerts-baremetal.yml`
   only watch `ipmi_sensor_state`. `ipmi_exporter` reports temperatures, fans,
   voltages, currents and power in their own metrics (`ipmi_temperature_state`,
   `ipmi_fan_speed_state`, `ipmi_voltage_state`, …), so those rules never fire for
   them. The note "Alert on `ipmi_sensor_state`" above is wrong for the same reason.
2. **Chassis intrusion alert can never fire.** It queries
   `ipmi_chassis_intrusion_state`, which `ipmi_exporter` does not export. Intrusion
   arrives as a generic sensor (`ipmi_sensor_state`, type `Physical Security`).
3. **node_exporter and promtail listen on all interfaces.** The Debian
   `prometheus-node-exporter` package defaults to `:9100` and promtail sets no
   `http_listen_address` (`:9080`). The other services bind to `127.0.0.1`; these
   two should too, especially on a host with a public IP.
