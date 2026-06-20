#!/usr/bin/env python3
"""
Applies the enable_policy sysfs attribute patch to int3400_thermal.c.

Strategy:
  1. Insert enable_policy_store() + DEVICE_ATTR_WO(enable_policy) before probe()
  2. In probe(): add device_create_file() just before the final "return 0;"
     — uses dev_warn on failure (no goto label needed, avoids kernel-version issues)
  3. In remove(): add device_remove_file() before kfree(priv)
"""
import sys, re

UUID = "b23ba85d-c8b7-3542-88de-8de2ffcfd698"

# Use a raw string to preserve the literal backslash-n sequences
ENABLE_POLICY_FUNC = (
    "\n"
    "static ssize_t enable_policy_store(struct device *dev,\n"
    "\t\t\t\t   struct device_attribute *attr,\n"
    "\t\t\t\t   const char *buf, size_t count)\n"
    "{\n"
    "\tstruct int3400_thermal_priv *priv = dev_get_drvdata(dev);\n"
    "\tint input, ret;\n"
    "\n"
    "\tret = kstrtouint(buf, 10, &input);\n"
    "\tif (ret)\n"
    "\t\treturn ret;\n"
    "\n"
    '\tdev_info(dev, "%s input: %d\\n", __func__, input);\n'
    "\tret = int3400_thermal_run_osc(priv->adev->handle,\n"
    f'\t\t\t\t      "{UUID}",\n'
    "\t\t\t\t      &input);\n"
    '\tdev_info(dev, "%s ret:%d\\n", __func__, ret);\n'
    "\tif (ret)\n"
    "\t\treturn -EIO;\n"
    "\n"
    "\treturn count;\n"
    "}\n"
    "\n"
    "static DEVICE_ATTR_WO(enable_policy);\n"
)

CREATE_FILE_CODE = (
    "\n"
    "\tif (device_create_file(&pdev->dev, &dev_attr_enable_policy))\n"
    '\t\tdev_warn(&pdev->dev, "int3400: failed to create enable_policy attr\\n");\n'
)

REMOVE_FILE_CODE = "\n\tdevice_remove_file(&pdev->dev, &dev_attr_enable_policy);"

def main():
    src_path = sys.argv[1]
    with open(src_path) as f:
        src = f.read()

    # ── Step 1: insert the function body before probe() ─────────────────────
    probe_pat = re.compile(r'\nstatic int int3400_thermal_probe\b')
    m = probe_pat.search(src)
    if not m:
        # Fallback: any "static int" function in this driver
        m = re.search(r'\nstatic int \w+\(', src)
    if not m:
        print("ERROR: cannot find probe() insertion point", file=sys.stderr)
        sys.exit(1)
    src = src[:m.start()] + ENABLE_POLICY_FUNC + src[m.start():]

    # ── Step 2: device_create_file in probe() just before final return 0 ────
    # Re-search probe after insertion
    probe_m = re.search(r'\nstatic int int3400_thermal_probe\b', src)
    if probe_m:
        probe_body = src[probe_m.start():]
        # Find all "\n\treturn 0;\n" occurrences inside the probe body
        ret_zeros = list(re.finditer(r'\n\treturn 0;\n', probe_body))
        if ret_zeros:
            last_ret = ret_zeros[-1]
            insert_abs = probe_m.start() + last_ret.start()
            src = src[:insert_abs] + CREATE_FILE_CODE + src[insert_abs:]

    # ── Step 3: device_remove_file in remove() before kfree(priv) ───────────
    remove_m = re.search(r'\nstatic (?:int|void) int3400_thermal_remove\b', src)
    if remove_m:
        remove_body = src[remove_m.start():]
        kfree_m = re.search(r'\n\tkfree\(priv\);', remove_body)
        if kfree_m:
            insert_abs = remove_m.start() + kfree_m.start()
            src = src[:insert_abs] + REMOVE_FILE_CODE + src[insert_abs:]

    with open(src_path, 'w') as f:
        f.write(src)

    print("int3400_patch.py: patch applied successfully")

if __name__ == "__main__":
    main()
