# Fix: CPU Throttling Under Load — Intel i7-1185G7 (TigerLake, INT3400/INTC1040)

**Upstream reference:** [intel/thermal_daemon issue #341](https://github.com/intel/thermal_daemon/issues/341)
**Universal installer:** [`install-throttle-fix.sh`](./install-throttle-fix.sh)

---

## The Problem

On systems with an Intel i7-1185G7 (11th Gen TigerLake, 28W UP3), the CPU drops to
very low frequencies under sustained load even when temperatures remain low and the
fan is not at its limit.

### Symptoms

- Without thermald: CPU drops to **~400 MHz** under load.
- With thermald (misconfigured): CPU is capped at **~1.8 GHz**.
- On Windows with Intel DTT: the CPU **oscillates** between 2.5–4.2 GHz unstably.
- **Expected frequency:** 3.8–4.3 GHz sustained depending on workload.

### Root Cause

The Intel DPTF (Dynamic Platform and Thermal Framework) firmware implements a
"thermal fallback" mechanism: if it does not detect that the OS is managing thermals
through DPTF/OSC policies, it aggressively reduces the power limit to ~10–15 W to
protect the hardware. The Linux `int3400_thermal` driver (INTC1040 device on
TigerLake) provided no mechanism to signal the firmware that the OS has active
thermal control.

---

## Test Environment

| Field | Value |
|---|---|
| CPU | Intel Core i7-1185G7 @ 3.00 GHz (boost up to 4.8 GHz) |
| Kernel | `7.0.x-1-cachyos` (CachyOS / Linux 7.0.x) |
| ACPI device | `INTC1040:00` (TigerLake version of INT3400) |
| Driver | `int3400_thermal` (`CONFIG_INT340X_THERMAL=m`) |
| Tjmax hardware | 100 °C (firmware TCC offset: 2 °C → throttle at 98 °C) |
| Fan max | 4800 RPM |

---

## Results

### Comparison

| Scenario | Peak frequency | Sustained 60 s | Stability |
|---|---|---|---|
| Linux **without fix** | ~1.8 GHz | ~1.8 GHz | Stable but slow |
| Windows + Intel DTT | ~4.2 GHz | 2.5–3.5 GHz (oscillates) | **Unstable** |
| **Linux with fix** | **~4.3 GHz** | **3.8–4.2 GHz** | **Fully stable** |

Linux with the fix **outperforms Windows in sustained throughput**: Windows with DTT
constantly renegotiates power limits causing continuous frequency swings. This fix
lets the CPU self-regulate by temperature, delivering flat and predictable
frequencies.

### Full boost curve (all-core, 60 s, starting from 59 °C)

```
Seconds   │ MHz range      │ Watts │ Temp     │ Phase
──────────┼────────────────┼───────┼──────────┼──────────────────────
   1–5 s  │ 4047 – 4300    │ 44–48W│ 85–95 °C │ PL2 burst
   6–20 s │ 3900 – 4300    │ 41–47W│ 93–96 °C │ PL2 sustained
  20–60 s │ 3800 – 4200    │ 40–45W│ 94–98 °C │ Sustained equilibrium
  post-60s│ 4300 – 4470    │  ~5 W │ 64–68 °C │ Single-core free boost
```

### Single-core maximum

```
Sustained: 4300 MHz    Peak: 4626 MHz    Temp: 67–71 °C
```

### sysbench cpu (prime up to 20000)

```
Single-core (1 thread):    1355 events/s
All-core   (8 threads):    5467 events/s   (multi-core efficiency: 4.03×)
```

---

## The Fix: Three Layers

### Layer 1 — Patched `int3400_thermal` module

Adds the `enable_policy` sysfs attribute, which lets userspace signal the firmware
that the OS has active DPTF control — without recompiling the full kernel (only the
single module is compiled, ~30 seconds).

**Why the original patch doesn't apply directly** — The patch (March 2022, kernel
~5.18) proposed changing the signature of `int3400_thermal_run_osc()`. In kernel
7.0.x that refactoring is already merged upstream. The only genuinely new change is
the `enable_policy` attribute. The patch was rebased by extracting only that part:

```diff
--- a/drivers/thermal/intel/int340x_thermal/int3400_thermal.c
+++ b/drivers/thermal/intel/int340x_thermal/int3400_thermal.c
+static ssize_t enable_policy_store(struct device *dev,
+                                   struct device_attribute *attr,
+                                   const char *buf, size_t count)
+{
+    struct int3400_thermal_priv *priv = dev_get_drvdata(dev);
+    int input, ret;
+
+    ret = kstrtouint(buf, 10, &input);
+    if (ret)
+        return ret;
+
+    ret = int3400_thermal_run_osc(priv->adev->handle,
+                                  "b23ba85d-c8b7-3542-88de-8de2ffcfd698",
+                                  &input);
+    if (ret)
+        return -EIO;
+    return count;
+}
+static DEVICE_ATTR_WO(enable_policy);
```

Plus `device_create_file`/`device_remove_file` in `probe()`/`remove()`.

> **Note on INTC1040:** On this firmware the `_OSC` call returns `-EPERM` (UUID not
> recognized). The attribute is ready for when a firmware update adds support.
> The performance gains come from layers 2 and 3.

### Layer 2 — Unlocked RAPL (both MSR and MMIO paths)

| Parameter | Value | Reason |
|---|---|---|
| PL1 (long-term) | 45 W | Above the real thermal ceiling; CPU self-regulates by temperature |
| PL2 (short-term) | 60 W | Initial burst up to 4.3 GHz |
| PL2 time window | 10 s | Extends the burst window from 2 ms to 10 s |

> **Critical discovery:** On TigerLake, Linux exposes **two simultaneous RAPL
> interfaces**:
>
> | Interface | Path | Module |
> |---|---|---|
> | MSR | `/sys/devices/virtual/powercap/intel-rapl/` | `intel_rapl_msr` |
> | MMIO | `/sys/devices/virtual/powercap/intel-rapl-mmio/` | `processor_thermal_rapl` |
>
> The CPU enforces the **lower** of the two. At boot the firmware initialises the
> MMIO path to **PL1 = 15 W / PL2 = 18.75 W** (from the ACPI PPCC table), capping
> the CPU at ~19 W even when the MSR path shows 45 W.
> **Both paths must be written.**

### Layer 3 — EPP performance

`energy_performance_preference = performance` on all cores: HWP always selects the
highest available P-states.

---

## Post-Update Behaviour (kernel updates)

When pacman updates `linux-cachyos`, it overwrites the patched `.ko.zst` with the
stock module. Without the patched module:

- The first ~5 s under load run normally at 45 W / 4.3 GHz (PL2 burst, RAPL still set)
- After ~5–10 s the firmware's DPTF thermal-fallback kicks in dynamically, reducing
  actual CPU power to ~15–20 W (~2.6–3.0 GHz), even though the RAPL sysfs still
  reads 45 W

**Solution:** a pacman hook (`/etc/pacman.d/hooks/int3400-patch.hook`) automatically
recompiles and reinstalls the patched module after every kernel upgrade.

---

## Quick Install (any distro)

```bash
sudo bash install-throttle-fix.sh
```

On Arch/CachyOS, the installer also sets up the pacman hook for automatic
rebuilds on kernel updates.

---

## Manual Installation (CachyOS / Arch)

```bash
# 1. Download source for the running kernel
KVER=$(uname -r)
KVER_MAIN=$(echo "$KVER" | grep -oP '^\d+\.\d+')
BASE="https://raw.githubusercontent.com/torvalds/linux/v${KVER_MAIN}"
SUBPATH="drivers/thermal/intel/int340x_thermal"

mkdir -p /tmp/int3400_build
curl -fsSL "$BASE/$SUBPATH/int3400_thermal.c" -o /tmp/int3400_build/int3400_thermal.c
curl -fsSL "$BASE/$SUBPATH/acpi_thermal_rel.h" -o /tmp/int3400_build/acpi_thermal_rel.h

# 2. Apply the patch
python3 int3400_patch.py /tmp/int3400_build/int3400_thermal.c

# 3. Build only the module
echo "obj-m := int3400_thermal.o" > /tmp/int3400_build/Makefile
make -C /usr/lib/modules/$KVER/build \
     M=/tmp/int3400_build \
     CC=clang LD=ld.lld LLVM=1 LLVM_IAS=1 \
     modules

# 4. Verify vermagic matches the running kernel
modinfo /tmp/int3400_build/int3400_thermal.ko | grep vermagic

# 5. Install
MODULE_PATH="/usr/lib/modules/$KVER/kernel/$SUBPATH/int3400_thermal.ko.zst"
cp "$MODULE_PATH" /tmp/int3400_thermal.ko.zst.backup
zstd -19 /tmp/int3400_build/int3400_thermal.ko -o "$MODULE_PATH"
depmod -a "$KVER"
rmmod int3400_thermal && modprobe int3400_thermal

# 6. Verify the attribute is present
ls /sys/devices/platform/INTC1040:00/enable_policy
```

### Boot script `/usr/local/bin/intel-dptf-policy.sh`

```bash
#!/bin/bash
# Intel INT3400/INTC1040 CPU throttle fix
# Ref: https://github.com/intel/thermal_daemon/issues/341

DPTF_DEV=$(find /sys/devices/platform -name "enable_policy" 2>/dev/null | head -1)
if [ -n "$DPTF_DEV" ]; then
    echo 1 > "$DPTF_DEV" 2>/dev/null || true
    echo 3 > "$DPTF_DEV" 2>/dev/null || true
fi

for cpu in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    echo performance > "$cpu" 2>/dev/null || true
done

# RAPL MSR path
RAPL=/sys/devices/virtual/powercap/intel-rapl/intel-rapl:0
[ -w "$RAPL/constraint_0_power_limit_uw" ] && echo 45000000 > "$RAPL/constraint_0_power_limit_uw" || true
[ -w "$RAPL/constraint_1_power_limit_uw" ] && echo 60000000 > "$RAPL/constraint_1_power_limit_uw" || true
[ -w "$RAPL/constraint_1_time_window_us" ] && echo 10000000 > "$RAPL/constraint_1_time_window_us" || true

# RAPL MMIO path — firmware sets this to 15W at boot; CPU takes the lower of both
RAPL_MMIO=/sys/devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0
[ -w "$RAPL_MMIO/constraint_0_power_limit_uw" ] && echo 45000000 > "$RAPL_MMIO/constraint_0_power_limit_uw" || true
[ -w "$RAPL_MMIO/constraint_1_power_limit_uw" ] && echo 60000000 > "$RAPL_MMIO/constraint_1_power_limit_uw" || true
```

### Service `/etc/systemd/system/intel-dptf-policy.service`

```ini
[Unit]
Description=Intel DPTF enable_policy and performance EPP
After=sysinit.target systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/intel-dptf-policy.sh

[Install]
WantedBy=multi-user.target
```

### Pacman hook `/etc/pacman.d/hooks/int3400-patch.hook`

Installed automatically by `install-throttle-fix.sh` on Arch/CachyOS.
Triggers `/usr/local/bin/int3400-rebuild.sh` after every kernel package upgrade.

```ini
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux-cachyos
Target = linux-cachyos-headers

[Action]
Description = Recompiling patched int3400_thermal module for DPTF fix...
When = PostTransaction
Exec = /usr/local/bin/int3400-rebuild.sh
AbortOnFail
```

The rebuild script (`/usr/local/bin/int3400-rebuild.sh`):
1. Downloads `int3400_thermal.c` for the new kernel version from kernel.org
2. Applies the `enable_policy` patch via `/usr/local/lib/int3400_patch.py`
3. Compiles with clang/LLVM to match the CachyOS kernel toolchain
4. Installs the `.ko.zst` with the correct vermagic
5. Hot-reloads the module and restarts the service

```bash
systemctl enable --now intel-dptf-policy.service
```

---

## Installed Files

| File | Purpose |
|---|---|
| `/usr/lib/modules/<kver>/.../int3400_thermal.ko.zst` | Patched module |
| `/usr/local/bin/intel-dptf-policy.sh` | Boot configuration script |
| `/etc/systemd/system/intel-dptf-policy.service` | systemd service (enabled) |
| `/etc/pacman.d/hooks/int3400-patch.hook` | Pacman hook — auto-rebuild on kernel update |
| `/usr/local/bin/int3400-rebuild.sh` | Rebuild script called by the hook |
| `/usr/local/lib/int3400_patch.py` | Python patcher for int3400_thermal.c |

---

## Verification

```bash
# Module loaded with patch
lsmod | grep int3400
ls /sys/devices/platform/INTC1040:00/enable_policy

# EPP on all cores
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference   # performance

# RAPL MSR limits
cat /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw  # 45000000
cat /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_1_power_limit_uw  # 60000000

# RAPL MMIO limits (must also be 45W — firmware sets this to 15W at boot)
cat /sys/devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw  # 45000000

# Service status
systemctl status intel-dptf-policy.service

# Pacman hook active
ls /etc/pacman.d/hooks/int3400-patch.hook

# TCC offset
rdmsr -p 0 0x1A2 | python3 -c "
import sys; v=int(sys.stdin.read().strip(),16)
tj=(v>>16)&0xFF; off=(v>>24)&0x3F
print(f'Tjmax={tj}°C  offset={off}°C  throttle_at={tj-off}°C')"
```

### Monitor under load

```bash
# Terminal 1 — stress
stress-ng --cpu 0 --timeout 60s

# Terminal 2 — real-time frequency, power and temperature
watch -n1 "
echo -n 'freq: '; grep 'cpu MHz' /proc/cpuinfo | awk '{if(\$4>m)m=\$4}END{printf \"%d MHz\n\",m}'
echo -n 'pwr:  '; python3 -c \"
import time
e1=int(open('/sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/energy_uj').read())
time.sleep(1)
e2=int(open('/sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/energy_uj').read())
print(f'{(e2-e1)/1e6:.1f}W')\"
echo -n 'temp: '; cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | awk 'BEGIN{m=0}{v=\$1/1000;if(v>m)m=v}END{printf \"%.0f°C\n\",m}'
"
```

---

## Troubleshooting

```bash
# Frequency drops after ~5s under load → patched module not loaded
ls /sys/devices/platform/INTC1040:00/enable_policy 2>/dev/null || echo "module not patched"
# Fix: run int3400-rebuild.sh
sudo /usr/local/bin/int3400-rebuild.sh

# RAPL MMIO is 15W instead of 45W → service didn't apply MMIO limits
cat /sys/devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw
# Fix: restart service
systemctl restart intel-dptf-policy.service

# What is throttling the CPU?
dmesg | grep -iE "thermal|rapl|throttl|power limit" | tail -20

# Is PROCHOT active? (1 = temperature throttle)
rdmsr -p 0 --decimal 0x19C | awk '{print "PROCHOT:", (($1>>4)&1)}'

# Is the pacman hook installed?
cat /etc/pacman.d/hooks/int3400-patch.hook
```

---

## Restore Original Module

```bash
KVER=$(uname -r)
MODULE_PATH="/usr/lib/modules/$KVER/kernel/drivers/thermal/intel/int340x_thermal/int3400_thermal.ko.zst"
cp /tmp/int3400_thermal.ko.zst.backup "$MODULE_PATH"
depmod -a "$KVER"
rmmod int3400_thermal && modprobe int3400_thermal
systemctl disable --now intel-dptf-policy.service
rm -f /etc/pacman.d/hooks/int3400-patch.hook
rm -f /usr/local/bin/int3400-rebuild.sh /usr/local/lib/int3400_patch.py
rm -f /usr/local/bin/intel-dptf-policy.sh
```
