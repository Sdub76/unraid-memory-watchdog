# Unraid memory watchdog

Capture evidence of host memory pressure before an Unraid server becomes unresponsive.

The watchdog runs on the host independently of Docker. It monitors **MemAvailable**, saves small incident reports to the boot device, and sends an Unraid **Alert** through configured notification channels. The default mode performs no automatic recovery action.

## Features

- RAM-based runtime with no routine monitoring writes to flash.
- Warning capture at 15% available memory for 60 seconds.
- Immediate capture when available memory reaches 5%.
- Optional memory PSI monitoring with automatic fallback when unavailable.
- Bounded memory, kernel, syslog, process and Docker diagnostics, with essential evidence written first.
- Persistent capture cooldowns, four-report daily limit, and 12-report retention.
- Alerts for saved/incomplete reports and unavailable captures.
- Optional Docker-only recovery: one restart attempt per host boot, with exclusions and memory attribution checks.
- No host reboot, array stop, cache drop, host-process termination or VM shutdown.

Host monitoring covers memory pressure from any source. Optional recovery targets Docker containers only; it does not prove which workload caused the pressure.

## Install

1. Download `unraid-memory-watchdog.sh` and save it on the server as `/boot/config/custom/unraid-memory-watchdog.sh`.
2. Configure Unraid's notification destinations for **Alerts**.
3. Create an entry in the **User Scripts** plugin and paste in [user-script-launcher.sh](user-script-launcher.sh).
4. Schedule it **At Startup of Array**, then run it once.

See the [deployment guide](DEPLOYMENT.md) for verification, configuration, optional Docker recovery, updates, and safe testing. The launcher runs the watchdog in the background and blocks duplicate instances.

## Defaults

| Setting | Default |
| --- | --- |
| Poll interval | 30 seconds |
| Warning | <=15% MemAvailable for 60 seconds |
| Critical capture | <=5% MemAvailable, first observation |
| Recovery/rearm | >=20% MemAvailable for 120 seconds |
| Notification severity | Alert |
| Automatic container restart | Disabled |
| Incident directory | `/boot/logs/unraid-memory-watchdog` |
| Report size | Less than 530,000 bytes |
| Capture budget | Four per rolling 24 hours |
| Retention | 12 reports |

## Safe tests

From the project directory on a Linux host, run as root:

```bash
bash tests/test-watchdog.sh
```

The suite uses simulated metrics, temporary directories and synthetic Docker/notification fixtures. It does not generate memory pressure, restart real containers, send real notifications, or write to the boot device. Root is required for daemon lifecycle checks.

## Limits and privacy

A userspace watchdog cannot guarantee evidence during abrupt OOM, power loss, kernel hangs or uninterruptible I/O. Remote syslog and appropriate container memory limits remain useful alongside it.

Reports can contain hostnames, process names, paths and network information from system logs. Inspect and redact reports before sharing. Keep the boot-device log directory private.

## License

[MIT](LICENSE).
