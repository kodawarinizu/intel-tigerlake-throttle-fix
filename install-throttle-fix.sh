#!/bin/bash
# =============================================================================
# Intel i7-1185G7 / INT3400 / INTC1040 — CPU Throttle Fix
# Ref: https://github.com/intel/thermal_daemon/issues/341
#
# Supports: Arch, CachyOS, Ubuntu/Debian, Fedora/RHEL, openSUSE
# Requires: kernel with CONFIG_INT340X_THERMAL=m, headers installed, systemd
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLU}[*]${NC} $*"; }
ok()    { echo -e "${GRN}[✓]${NC} $*"; }
warn()  { echo -e "${YEL}[!]${NC} $*"; }
die()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

KVER=$(uname -r)
KBUILD="/usr/lib/modules/$KVER/build"
BUILD_DIR=$(mktemp -d /tmp/int3400_fix_XXXXXX)
trap 'rm -rf "$BUILD_DIR"' EXIT

# =============================================================================
# 1. Verificar hardware y requisitos
# =============================================================================
check_hardware() {
    info "Checking hardware..."

    local cpu
    cpu=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2)
    echo "  CPU: $cpu"

    # Verificar que sea Intel TigerLake / compatible (INT3400 o INTC1040)
    if ! find /sys/devices/platform -maxdepth 1 \( -name "INT3400:*" -o -name "INTC1040:*" \) \
         -type d 2>/dev/null | grep -q .; then
        warn "INT3400/INTC1040 device not found. This fix may not apply."
        warn "Continuing anyway with RAPL/EPP settings..."
        MODULE_NEEDED=false
    else
        local dev
        dev=$(find /sys/devices/platform -maxdepth 1 \( -name "INT3400:*" -o -name "INTC1040:*" \) \
              -type d 2>/dev/null | head -1)
        ok "DPTF device: $(basename "$dev")"
        DPTF_SYSFS="$dev"
        MODULE_NEEDED=true
    fi

    # Check if int3400_thermal is a module or built-in
    if [ "${MODULE_NEEDED:-false}" = true ]; then
        if grep -qr "^CONFIG_INT340X_THERMAL=m" "/usr/lib/modules/$KVER/build/.config" \
                                                  "/boot/config-$KVER" \
                                                  "/proc/config.gz" 2>/dev/null; then
            ok "CONFIG_INT340X_THERMAL=m (module) — can be patched without recompiling the kernel"
        elif zcat /proc/config.gz 2>/dev/null | grep -q "^CONFIG_INT340X_THERMAL=m"; then
            ok "CONFIG_INT340X_THERMAL=m (module)"
        else
            warn "CONFIG_INT340X_THERMAL is not a module (=y or not found)"
            warn "Only RAPL/EPP settings will be applied"
            MODULE_NEEDED=false
        fi

        # Check if patch is already applied
        if [ -f "$DPTF_SYSFS/enable_policy" ]; then
            ok "Attribute .enable_policy. already exists — module already patched"
            MODULE_NEEDED=false
            ALREADY_PATCHED=true
        else
            ALREADY_PATCHED=false
        fi
    fi
}

# =============================================================================
# 2. Detectar distro e instalar dependencias
# =============================================================================
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_LIKE="${ID_LIKE:-}"
    else
        DISTRO_ID="unknown"
    fi
    info "Distro: ${PRETTY_NAME:-$DISTRO_ID}"
}

install_deps() {
    [ "${MODULE_NEEDED:-false}" = false ] && return 0
    info "Installing build dependencies..."

    case "$DISTRO_ID" in
        arch|cachyos|manjaro|endeavouros)
            pacman -S --noconfirm --needed base-devel clang llvm lld linux-headers 2>/dev/null \
            || pacman -S --noconfirm --needed base-devel gcc linux-headers
            ;;
        ubuntu|debian|linuxmint|pop)
            apt-get install -y --no-install-recommends \
                build-essential gcc "linux-headers-$KVER" \
                "linux-headers-$(dpkg --print-architecture)" 2>/dev/null \
            || apt-get install -y build-essential gcc "linux-headers-generic"
            ;;
        fedora)
            dnf install -y gcc make kernel-devel-"$KVER" elfutils-libelf-devel
            ;;
        rhel|centos|almalinux|rocky)
            dnf install -y gcc make "kernel-devel-$KVER" elfutils-libelf-devel
            ;;
        opensuse*|suse*)
            zypper install -y gcc make "kernel-default-devel"
            ;;
        *)
            if [[ "$DISTRO_LIKE" == *arch* ]]; then
                pacman -S --noconfirm --needed base-devel gcc linux-headers
            elif [[ "$DISTRO_LIKE" == *debian* || "$DISTRO_LIKE" == *ubuntu* ]]; then
                apt-get install -y build-essential gcc "linux-headers-$KVER"
            elif [[ "$DISTRO_LIKE" == *fedora* || "$DISTRO_LIKE" == *rhel* ]]; then
                dnf install -y gcc make "kernel-devel-$KVER"
            else
                warn "Unknown distro. Make sure you have: gcc/clang, make, kernel-headers"
            fi
            ;;
    esac
    ok "Dependencies ready"
}

# =============================================================================
# 3. Obtener el source de int3400_thermal.c
# =============================================================================
get_source() {
    [ "${MODULE_NEEDED:-false}" = false ] && return 0
    info "Looking for int3400_thermal.c source..."

    local src_c src_h
    local driver_subpath="drivers/thermal/intel/int340x_thermal"

    # Method 1: source already available locally (extracted Arch PKGBUILD, etc.)
    for search_base in \
        "/usr/src/linux-$KVER" \
        "/usr/src/linux" \
        "/lib/modules/$KVER/source" \
        "$HOME/linux-cachyos/linux-cachyos/src/"*/ \
        "/usr/src/kernels/$KVER"; do
        if [ -f "$search_base/$driver_subpath/int3400_thermal.c" ]; then
            src_c="$search_base/$driver_subpath/int3400_thermal.c"
            src_h="$search_base/$driver_subpath/acpi_thermal_rel.h"
            ok "Source found locally: $search_base"
            break
        fi
    done

    # Method 2: download from kernel.org/GitHub based on the running kernel version
    if [ -z "${src_c:-}" ]; then
        local kver_short
        # Extract base version (e.g. "7.0.11" from "7.0.11-1-cachyos")
        kver_short=$(echo "$KVER" | grep -oP '^\d+\.\d+\.?\d*')
        info "Downloading source for kernel $kver_short from kernel.org..."

        local base_url="https://raw.githubusercontent.com/torvalds/linux/v${kver_short}/${driver_subpath}"

        # For custom distro kernels (CachyOS, etc.) also try their fork
        local cachy_url="https://raw.githubusercontent.com/CachyOS/linux/cachyos-${kver_short}/${driver_subpath}"

        for url_base in "$cachy_url" "$base_url"; do
            if curl -fsSL --max-time 30 \
                    "${url_base}/int3400_thermal.c" \
                    -o "$BUILD_DIR/int3400_thermal.c" 2>/dev/null && \
               curl -fsSL --max-time 30 \
                    "${url_base}/acpi_thermal_rel.h" \
                    -o "$BUILD_DIR/acpi_thermal_rel.h" 2>/dev/null; then
                ok "Source downloaded from: $url_base"
                src_c="$BUILD_DIR/int3400_thermal.c"
                src_h="$BUILD_DIR/acpi_thermal_rel.h"
                break
            fi
        done
    fi

    if [ -z "${src_c:-}" ]; then
        warn "Could not obtain int3400_thermal.c source"
        warn "Only RAPL/EPP settings will be applied"
        MODULE_NEEDED=false
        return 1
    fi

    cp "$src_c" "$BUILD_DIR/int3400_thermal.c"
    [ -f "${src_h:-}" ] && cp "$src_h" "$BUILD_DIR/acpi_thermal_rel.h"
    SOURCE_FILE="$BUILD_DIR/int3400_thermal.c"
}

# =============================================================================
# 4. Aplicar el parche (rebasado, compatible con kernels modernos)
# =============================================================================
apply_patch() {
    [ "${MODULE_NEEDED:-false}" = false ] && return 0
    info "Applying enable_policy patch..."

    local src="$BUILD_DIR/int3400_thermal.c"

    # Check if source already has enable_policy (future kernels may include it)
    if grep -q "enable_policy_store" "$src"; then
        ok "Source already contains enable_policy — no patch needed"
        return 0
    fi

    # Detect int3400_thermal_run_osc signature to select the right patch strategy
    local osc_sig
    osc_sig=$(grep -n "^static int int3400_thermal_run_osc" "$src" | head -1)

    if echo "$osc_sig" | grep -q "char \*uuid_str.*int \*enable"; then
        # Firma moderna (kernel >= ~6.1): (handle, char *uuid_str, int *enable)
        _patch_modern "$src"
    elif echo "$osc_sig" | grep -q "enum int3400_thermal_uuid uuid.*bool enable"; then
        # Firma antigua (kernel <= ~5.18): (handle, enum uuid, bool enable)
        _patch_legacy "$src"
    else
        warn "int3400_thermal_run_osc signature not recognized, trying modern patch..."
        _patch_modern "$src" || {
            warn "Patch failed — applying RAPL/EPP only"
            MODULE_NEEDED=false
            return 1
        }
    fi
}

_patch_modern() {
    # Para kernels con la firma moderna: (handle, char *uuid_str, int *enable)
    local src="$1"
    local DPTF_UUID="b23ba85d-c8b7-3542-88de-8de2ffcfd698"

    # Find insertion point: just before current_uuid_store or the
    # first sysfs function after set_os_uuid_mask / int3400_thermal_run_osc
    local insert_after
    insert_after=$(grep -n "^static int set_os_uuid_mask\|^static ssize_t current_uuid_store\|^static int int3400_thermal_get_uuids" \
                   "$src" | tail -1 | cut -d: -f1)

    if [ -z "$insert_after" ]; then
        # Fallback: insert after the first function that calls run_osc
        insert_after=$(grep -n "int3400_thermal_run_osc" "$src" | tail -1 | cut -d: -f1)
        # Find the closing brace of that function
        insert_after=$(awk "NR>$insert_after && /^}/ {print NR; exit}" "$src")
    fi

    [ -z "$insert_after" ] && { warn "Insertion point not found"; return 1; }

    # Insert enable_policy_store and DEVICE_ATTR after insert_after
    local new_code
    new_code=$(cat <<EOF

static ssize_t enable_policy_store(struct device *dev,
				    struct device_attribute *attr,
				    const char *buf, size_t count)
{
	struct int3400_thermal_priv *priv = dev_get_drvdata(dev);
	int input, ret;

	ret = kstrtouint(buf, 10, &input);
	if (ret)
		return ret;

	dev_info(dev, "%s input: %d\\n", __func__, input);
	ret = int3400_thermal_run_osc(priv->adev->handle,
				      "$DPTF_UUID",
				      &input);
	dev_info(dev, "%s ret:%d\\n", __func__, ret);
	if (ret)
		return -EIO;

	return count;
}

static DEVICE_ATTR_WO(enable_policy);
EOF
)
    # Insertar en el archivo
    local tmpf="$BUILD_DIR/int3400_patched.c"
    awk -v line="$insert_after" -v code="$new_code" \
        'NR==line{print; print code; next} {print}' "$src" > "$tmpf"
    mv "$tmpf" "$src"

    # Add device_create_file in probe()
    _patch_probe_remove "$src"

    ok "Modern patch applied (enable_policy_store + DEVICE_ATTR_WO)"
}

_patch_legacy() {
    # Para kernels con firma antigua: int3400_thermal_run_osc(handle, enum uuid, bool enable)
    # These kernels also need the run_osc refactoring
    warn "Kernel with legacy run_osc signature. Applying full original patch..."
    local src="$1"

    # Download original patch and apply with maximum fuzz
    local PATCH_URL="https://lore.kernel.org/lkml/20220310014638.2927385-1-srinivas.pandruvada@linux.intel.com/raw"
    local tmpatch="$BUILD_DIR/original.patch"

    if curl -fsSL --max-time 30 "$PATCH_URL" -o "$tmpatch" 2>/dev/null; then
        cd "$BUILD_DIR"
        if patch -p1 --fuzz=5 < "$tmpatch" 2>/dev/null; then
            ok "Original patch applied successfully"
        else
            warn "Original patch failed — applying RAPL/EPP only"
            MODULE_NEEDED=false
        fi
    else
        warn "Could not download original patch — applying RAPL/EPP only"
        MODULE_NEEDED=false
    fi
}

_patch_probe_remove() {
    # Add device_create_file/device_remove_file in probe() and remove()
    local src="$1"

    # In probe: add device_create_file just before int3400_thermal_get_uuids
    # Pattern: find pdev/adev initialization, insert after
    sed -i 's/\(result = int3400_thermal_get_uuids(priv);\)/\n\tresult = device_create_file(\&pdev->dev, \&dev_attr_enable_policy);\n\tif (result)\n\t\tgoto free_priv;\n\n\t\1/' "$src" 2>/dev/null || true

    # In remove: add device_remove_file before kfree(priv)
    sed -i 's/\(\tkfree(priv);\n\treturn 0;\n}\)$/\tdevice_remove_file(\&pdev->dev, \&dev_attr_enable_policy);\n\1/' "$src" 2>/dev/null || true

    # More robust alternative for remove()
    if ! grep -q "device_remove_file.*enable_policy" "$src"; then
        # Find the final kfree in remove and prepend
        local tmpf="$BUILD_DIR/int3400_probe.c"
        awk '
        /kfree\(priv\);/ && found_remove {
            print "\tdevice_remove_file(&pdev->dev, &dev_attr_enable_policy);";
            found_remove=0
        }
        /static void int3400_thermal_remove/ { found_remove=1 }
        { print }
        ' "$src" > "$tmpf" && mv "$tmpf" "$src"
    fi
}

# =============================================================================
# 5. Compile the module
# =============================================================================
build_module() {
    [ "${MODULE_NEEDED:-false}" = false ] && return 0
    info "Compiling int3400_thermal.ko..."

    # Create minimal Makefile
    echo "obj-m := int3400_thermal.o" > "$BUILD_DIR/Makefile"

    # Detectar si usar clang o gcc
    local make_extra=""
    if command -v clang &>/dev/null && \
       grep -q "clang\|LLVM" "$KBUILD/Makefile" 2>/dev/null; then
        make_extra="CC=clang LD=ld.lld LLVM=1 LLVM_IAS=1"
        info "Compiling with clang/LLVM"
    else
        info "Compiling with gcc"
    fi

    # Compilar
    if ! make -C "$KBUILD" M="$BUILD_DIR" $make_extra modules 2>&1; then
        warn "Compilation failed — applying RAPL/EPP only"
        MODULE_NEEDED=false
        return 1
    fi

    # Verificar vermagic
    local vm
    vm=$(modinfo "$BUILD_DIR/int3400_thermal.ko" 2>/dev/null | grep vermagic | awk '{print $2}')
    if [ "$vm" != "$KVER" ]; then
        warn "vermagic mismatch: module=$vm, kernel=$KVER"
        warn "Module may not load — applying RAPL/EPP only"
        MODULE_NEEDED=false
        return 1
    fi

    ok "Module compiled: vermagic=$vm"
}

# =============================================================================
# 6. Install the module
# =============================================================================
install_module() {
    [ "${MODULE_NEEDED:-false}" = false ] && return 0
    [ "${ALREADY_PATCHED:-false}" = true ] && return 0
    info "Installing patched module..."

    local driver_path="kernel/drivers/thermal/intel/int340x_thermal"
    local ko_base="/usr/lib/modules/$KVER/$driver_path/int3400_thermal.ko"

    # Detect compression format of the installed module
    local installed_ko ext compress_cmd
    if   [ -f "${ko_base}.zst" ]; then installed_ko="${ko_base}.zst"; ext=".zst"; compress_cmd="zstd -19 -f"
    elif [ -f "${ko_base}.xz"  ]; then installed_ko="${ko_base}.xz";  ext=".xz";  compress_cmd="xz -f"
    elif [ -f "${ko_base}.gz"  ]; then installed_ko="${ko_base}.gz";  ext=".gz";  compress_cmd="gzip -f"
    elif [ -f "${ko_base}"     ]; then installed_ko="${ko_base}";      ext="";     compress_cmd="cp"
    else
        warn "Original module not found at $ko_base*"
        warn "Applying RAPL/EPP only"
        MODULE_NEEDED=false
        return 1
    fi

    # Backup
    cp "$installed_ko" "/tmp/int3400_thermal_original${ext}.backup"
    ok "Backup saved: /tmp/int3400_thermal_original${ext}.backup"

    # Comprimir e instalar
    if [ -n "$ext" ]; then
        $compress_cmd "$BUILD_DIR/int3400_thermal.ko" -o "/tmp/int3400_thermal_new${ext}"
        cp "/tmp/int3400_thermal_new${ext}" "$installed_ko"
    else
        cp "$BUILD_DIR/int3400_thermal.ko" "$installed_ko"
    fi

    depmod -a "$KVER"

    # Hot-reload if already loaded
    if lsmod | grep -q "^int3400_thermal"; then
        rmmod int3400_thermal 2>/dev/null || true
    fi
    modprobe int3400_thermal

    # Verificar atributo
    sleep 1
    local dptf_dev
    dptf_dev=$(find /sys/devices/platform -name "enable_policy" 2>/dev/null | head -1)
    if [ -n "$dptf_dev" ]; then
        ok "Attribute enable_policy present: $dptf_dev"
    else
        warn "Module loaded but enable_policy not found (firmware may not support this OSC UUID)"
    fi
}

# =============================================================================
# 7. Instalar servicio systemd
# =============================================================================
install_service() {
    info "Installing systemd service..."

    if ! command -v systemctl &>/dev/null; then
        warn "systemd not available — falling back to rc.local"
        _install_rclocal
        return
    fi

    cat > /usr/local/bin/intel-dptf-policy.sh << 'SCRIPT_EOF'
#!/bin/bash
# Intel INT3400/INTC1040 CPU throttle fix
# Ref: https://github.com/intel/thermal_daemon/issues/341

# Activate DPTF policy if the patched module is loaded
DPTF_DEV=$(find /sys/devices/platform -name "enable_policy" 2>/dev/null | head -1)
if [ -n "$DPTF_DEV" ]; then
    echo 1 > "$DPTF_DEV" 2>/dev/null || true
    echo 3 > "$DPTF_DEV" 2>/dev/null || true
fi

# EPP=performance on all cores (HWP always picks highest P-states)
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    echo performance > "$cpu" 2>/dev/null || true
done

# RAPL: PL1=45W / PL2=60W / PL2 window=10s
# CPU self-regulates by temperature — the fan defines the real limit
RAPL=/sys/devices/virtual/powercap/intel-rapl/intel-rapl:0
[ -w "$RAPL/constraint_0_power_limit_uw" ] && echo 45000000 > "$RAPL/constraint_0_power_limit_uw"
[ -w "$RAPL/constraint_1_power_limit_uw" ] && echo 60000000 > "$RAPL/constraint_1_power_limit_uw"
[ -w "$RAPL/constraint_1_time_window_us" ] && echo 10000000 > "$RAPL/constraint_1_time_window_us"
SCRIPT_EOF

    chmod +x /usr/local/bin/intel-dptf-policy.sh

    cat > /etc/systemd/system/intel-dptf-policy.service << 'SVC_EOF'
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
SVC_EOF

    systemctl daemon-reload
    systemctl enable intel-dptf-policy.service
    ok "Service intel-dptf-policy installed and enabled"
}

_install_rclocal() {
    local rc="/etc/rc.local"
    [ ! -f "$rc" ] && echo "#!/bin/bash" > "$rc" && chmod +x "$rc"
    if ! grep -q "intel-dptf-policy" "$rc"; then
        sed -i '/^exit 0/i /usr/local/bin/intel-dptf-policy.sh\n' "$rc" 2>/dev/null \
        || echo "/usr/local/bin/intel-dptf-policy.sh" >> "$rc"
    fi
    ok "Script added to $rc"
}

# =============================================================================
# 8. Aplicar ajustes inmediatamente (sin reboot)
# =============================================================================
apply_now() {
    info "Applying settings live (no reboot needed)..."
    /usr/local/bin/intel-dptf-policy.sh
    ok "Settings applied"
}

# =============================================================================
# Resumen final
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GRN}════════════════════════════════════════════════════════${NC}"
    echo -e "${GRN}  Fix installed successfully${NC}"
    echo -e "${GRN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Current state:"
    echo -n "  EPP:        "; cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "N/A"
    echo -n "  RAPL PL1:   "; awk '{printf "%.0fW\n", $1/1000000}' /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null || echo "N/A"
    echo -n "  RAPL PL2:   "; awk '{printf "%.0fW\n", $1/1000000}' /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_1_power_limit_uw 2>/dev/null || echo "N/A"
    echo -n "  enable_policy: "
    find /sys/devices/platform -name "enable_policy" 2>/dev/null | head -1 | xargs -I{} dirname {} | xargs -I{} echo "present at {}" || echo "not available (module not patched)"
    echo ""
    echo "Expected behavior under load:"
    echo "   0–10 s:  burst 4.0–4.3 GHz (PL2=60W)"
    echo "  10-30 s:  3.9-4.0 GHz (thermal stabilization)"
    echo "  30 s+  :  3.8-3.9 GHz (sustained thermal equilibrium)"
    echo ""
    echo "To uninstall:"
    echo "  systemctl disable --now intel-dptf-policy.service"
    [ -f /tmp/int3400_thermal_original*.backup 2>/dev/null ] && \
    echo "  cp /tmp/int3400_thermal_original*.backup \\"
    echo "     /usr/lib/modules/\$(uname -r)/kernel/drivers/thermal/intel/int340x_thermal/int3400_thermal.ko*"
    echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo -e "${BLU}"
    echo "  Intel i7-1185G7 / INT3400 CPU Throttle Fix"
    echo "  Ref: github.com/intel/thermal_daemon/issues/341"
    echo -e "${NC}"

    [ "$(id -u)" != "0" ] && die "Must run as root: sudo $0"
    [ ! -d "$KBUILD" ]    && die "Kernel headers not found at $KBUILD"

    MODULE_NEEDED=true
    ALREADY_PATCHED=false

    check_hardware
    detect_distro
    install_deps
    get_source
    apply_patch
    build_module
    install_module
    install_service
    apply_now
    print_summary
}

main "$@"
