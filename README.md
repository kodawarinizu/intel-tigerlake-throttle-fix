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
through DPTF/OSC policies, it aggressively reduces PL1 to ~10 W to protect the
hardware. The Linux `int3400_thermal` driver (INTC1040 device on TigerLake) provided
no mechanism to signal the firmware that the OS has active thermal control.

---

## Test Environment

| Field | Value |
|---|---|
| CPU | Intel Core i7-1185G7 @ 3.00 GHz (boost up to 4.8 GHz) |
| Kernel | `7.0.11-1-cachyos` (CachyOS / Linux 7.0.11) |
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
| **Linux with fix** | **~4.3 GHz** | **3.8–3.9 GHz** | **Fully stable** |

Linux with the fix **outperforms Windows in sustained throughput**: Windows with DTT
constantly renegotiates power limits causing continuous frequency swings. This fix
lets the CPU self-regulate by temperature, delivering flat and predictable
frequencies.

### Full boost curve (all-core, 60 s, starting from 59 °C)

```
Seconds   │ MHz range      │ Watts │ Temp     │ Phase
──────────┼────────────────┼───────┼──────────┼──────────────────────
   1–3 s  │ 4047 – 4300    │ 44–48W│ 85–93 °C │ PL2 maximum burst
   4–10 s │ 4065 – 4300    │ 43–47W│ 94–98 °C │ PL2 sustained
  11–20 s │ 3900 – 4200    │ 37–42W│ 95–99 °C │ Thermal transition
  20–60 s │ 3800 – 3900    │ 35–37W│ 95–99 °C │ Sustained equilibrium
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
single module).

**Why the original patch doesn't apply directly** — The patch (March 2022, kernel
~5.18) proposed changing the signature of `int3400_thermal_run_osc()`. In kernel
7.0.11 that refactoring is already merged upstream. The only genuinely new change is
the `enable_policy` attribute. The patch was rebased by extracting only that part:

```diff
--- a/drivers/thermal/intel/int340x_thermal/int3400_thermal.c
+++ b/drivers/thermal/intel/int340x_thermal/int3400_thermal.c
@@ -192,6 +192,30 @@ static int set_os_uuid_mask(...)
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

Plus registration and cleanup of the attribute in `probe()` and `remove()`.

> **Note on INTC1040:** On this firmware the `_OSC` call returns `-EPERM` (UUID not
> recognized in this firmware revision). The attribute is ready for when a firmware
> update adds support. The performance gains come from layers 2 and 3.

### Layer 2 — Unlocked RAPL

| Parameter | Value | Reason |
|---|---|---|
| PL1 (long-term) | 45 W | Above the real thermal ceiling (~35 W); the CPU self-regulates by temperature, not by RAPL |
| PL2 (short-term) | 60 W | Initial burst up to 4.3 GHz |
| PL2 time window | 10 s | Extends the burst window from 2 ms to 10 s |

### Layer 3 — EPP performance

`energy_performance_preference = performance` on all cores: HWP always selects the
highest available P-states.

---

## Quick Install (any distro)

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USER/intel-tigerlake-throttle-fix/main/install-throttle-fix.sh)
```

---

## Manual Installation (CachyOS / Arch)

```bash
# 1. Copy patched source from the already-prepared PKGBUILD
SRCDIR=~/linux-cachyos/linux-cachyos/src/cachyos-7.0.11-1/drivers/thermal/intel/int340x_thermal

# 2. Build only the module
mkdir -p /tmp/int3400_build
cp $SRCDIR/int3400_thermal.c $SRCDIR/acpi_thermal_rel.h /tmp/int3400_build/
echo "obj-m := int3400_thermal.o" > /tmp/int3400_build/Makefile

make -C /usr/lib/modules/$(uname -r)/build \
     M=/tmp/int3400_build \
     CC=clang LD=ld.lld LLVM=1 LLVM_IAS=1 \
     modules

# 3. Verify vermagic matches the running kernel
modinfo /tmp/int3400_build/int3400_thermal.ko | grep vermagic

# 4. Install
KVER=$(uname -r)
MODULE_PATH="/usr/lib/modules/$KVER/kernel/drivers/thermal/intel/int340x_thermal/int3400_thermal.ko.zst"
cp "$MODULE_PATH" /tmp/int3400_thermal.ko.zst.backup
zstd -19 /tmp/int3400_build/int3400_thermal.ko -o "$MODULE_PATH"
depmod -a "$KVER"
rmmod int3400_thermal && modprobe int3400_thermal

# 5. Verify the attribute is present
ls /sys/devices/platform/INTC1040:00/enable_policy
```

### Boot script `/usr/local/bin/intel-dptf-policy.sh`

```bash
#!/bin/bash
DPTF_DEV=$(find /sys/devices/platform -name "enable_policy" 2>/dev/null | head -1)
[ -n "$DPTF_DEV" ] && { echo 1 > "$DPTF_DEV" 2>/dev/null; echo 3 > "$DPTF_DEV" 2>/dev/null; } || true

for cpu in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    echo performance > "$cpu" 2>/dev/null || true
done

RAPL=/sys/devices/virtual/powercap/intel-rapl/intel-rapl:0
[ -w "$RAPL/constraint_0_power_limit_uw" ] && echo 45000000 > "$RAPL/constraint_0_power_limit_uw"
[ -w "$RAPL/constraint_1_power_limit_uw" ] && echo 60000000 > "$RAPL/constraint_1_power_limit_uw"
[ -w "$RAPL/constraint_1_time_window_us" ] && echo 10000000 > "$RAPL/constraint_1_time_window_us"
```

### Service `/etc/systemd/system/intel-dptf-policy.service`

```ini
[Unit]
Description=Intel DPTF enable_policy and performance EPP
After=systemd-modules-load.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/intel-dptf-policy.sh

[Install]
WantedBy=multi-user.target
```

```bash
systemctl enable --now intel-dptf-policy.service
```

---

## Verification

```bash
# Module loaded
lsmod | grep int3400

# Attribute present
ls /sys/devices/platform/INTC1040:00/enable_policy

# EPP on all cores
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference   # performance

# RAPL limits
cat /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw  # 45000000
cat /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_1_power_limit_uw  # 60000000

# Platform profile
cat /sys/firmware/acpi/platform_profile                                   # performance

# Service status
systemctl status intel-dptf-policy.service

# TCC offset (actual throttle point)
rdmsr -p 0 0x1A2 | python3 -c "
import sys; v=int(sys.stdin.read().strip(),16)
tj=(v>>16)&0xFF; off=(v>>24)&0x3F
print(f'Tjmax={tj}°C  offset={off}°C  throttle_at={tj-off}°C')"
```

### Monitor under load

```bash
# Terminal 1 — stress
stress-ng --cpu 0 --timeout 60s

# Terminal 2 — real-time frequency and temperature
watch -n1 "grep 'cpu MHz' /proc/cpuinfo | awk '{print \$4}' | sort -rn | head -1 | \
xargs -I{} sh -c 'echo -n \"max: {} MHz  \"; \
cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | \
awk \"BEGIN{m=0} {v=\\\$1/1000; if(v>m)m=v} END{printf \\\"temp: %.0f°C\\n\\\",m}\"'"
```

---

## Troubleshooting

```bash
# What is throttling the CPU?
dmesg | grep -iE "thermal|rapl|throttl|power limit" | tail -20

# Is PROCHOT active?  (1 = throttling due to temperature)
rdmsr -p 0 --decimal 0x19C | awk '{print "PROCHOT:", (($1>>4)&1)}'

# Did the firmware lower the RAPL limit?
cat /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw
# If < 45000000, either the service isn't running or the firmware overrode it
systemctl restart intel-dptf-policy.service
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
```

---

## Modified Files

| File | Description |
|---|---|
| `/usr/lib/modules/7.0.11-1-cachyos/.../int3400_thermal.ko.zst` | Patched module |
| `/tmp/int3400_thermal.ko.zst.backup` | Original module backup |
| `/usr/local/bin/intel-dptf-policy.sh` | Boot configuration script |
| `/etc/systemd/system/intel-dptf-policy.service` | systemd service (enabled) |
| `~/linux-cachyos/linux-cachyos/0001-thermal-int340x-Add-new-attribute-for-policy-info.patch` | Rebased patch for kernel 7.0.11 |
