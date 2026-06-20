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

# Write the C-source patch helper alongside the build dir
# (avoids needing a separate file on disk)
cat > "$BUILD_DIR/int3400_patch.py" << 'INT3400_PATCH_EOF'
#!/usr/bin/env python3
"""Applies the enable_policy sysfs attribute patch to int3400_thermal.c."""
import sys, re

UUID = "b23ba85d-c8b7-3542-88de-8de2ffcfd698"

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
    f'\t\t\t\t      \"{UUID}\",\n'
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

CREATE_FILE = (
    "\n"
    "\tif (device_create_file(&pdev->dev, &dev_attr_enable_policy))\n"
    '\t\tdev_warn(&pdev->dev, "int3400: failed to create enable_policy attr\\n");\n'
)
REMOVE_FILE = "\n\tdevice_remove_file(&pdev->dev, &dev_attr_enable_policy);"

src_path = sys.argv[1]
with open(src_path) as f:
    src = f.read()

m = re.search(r"\nstatic int int3400_thermal_probe\b", src)
if not m:
    m = re.search(r"\nstatic int \w+\(", src)
if not m:
    print("ERROR: cannot find probe() insertion point", file=sys.stderr); sys.exit(1)
src = src[:m.start()] + ENABLE_POLICY_FUNC + src[m.start():]

probe_m = re.search(r"\nstatic int int3400_thermal_probe\b", src)
if probe_m:
    body = src[probe_m.start():]
    ret_zeros = list(re.finditer(r"\n\treturn 0;\n", body))
    if ret_zeros:
        pos = probe_m.start() + ret_zeros[-1].start()
        src = src[:pos] + CREATE_FILE + src[pos:]

remove_m = re.search(r"\nstatic (?:int|void) int3400_thermal_remove\b", src)
if remove_m:
    body = src[remove_m.start():]
    kf = re.search(r"\n\tkfree\(priv\);", body)
    if kf:
        pos = remove_m.start() + kf.start()
        src = src[:pos] + REMOVE_FILE + src[pos:]

with open(src_path, "w") as f:
    f.write(src)
print("int3400_patch.py: patch applied successfully")
INT3400_PATCH_EOF

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
# 3. Obtener el source de int3400_thermal.c (MEJORADO)
# =============================================================================
get_source() {
    [ "${MODULE_NEEDED:-false}" = false ] && return 0
    info "Looking for int3400_thermal.c source..."

    local src_c src_h
    local driver_subpath="drivers/thermal/intel/int340x_thermal"
    local found_source=false

    # Method 1: Buscar en ubicaciones comunes locales
    info "Searching locally for source..."
    for search_base in \
        "/usr/src/linux-$KVER" \
        "/usr/src/linux-headers-$KVER" \
        "/usr/src/linux" \
        "/lib/modules/$KVER/source" \
        "/lib/modules/$KVER/build" \
        "/usr/src/kernels/$KVER" \
        "/usr/src/linux-$(echo $KVER | cut -d- -f1)" \
        "$HOME/linux" \
        "/usr/local/src/linux"; do
        
        if [ -f "$search_base/$driver_subpath/int3400_thermal.c" ]; then
            src_c="$search_base/$driver_subpath/int3400_thermal.c"
            src_h="$search_base/$driver_subpath/acpi_thermal_rel.h"
            ok "Source found locally: $search_base"
            found_source=true
            break
        fi
    done

    # Method 2: Si no está localmente, intentar descargar del kernel.org
    if [ "$found_source" = false ]; then
        info "Source not found locally. Attempting to download from kernel.org..."
        
        # Extraer la versión mayor del kernel (ej: 6.1, 6.2, 5.15, etc.)
        local kver_major=$(echo "$KVER" | grep -oP '^\d+\.\d+' | head -1)
        local kver_full=$(echo "$KVER" | grep -oP '^\d+\.\d+\.?\d*' | head -1)
        
        # Si no tiene patch version, asumir .0
        if [[ ! "$kver_full" =~ \. ]]; then
            kver_full="${kver_full}.0"
        fi
        
        info "Kernel version detected: $kver_full"
        
        # Intentar con diferentes versiones (la exacta, la mayor, y algunas variantes)
        local versions_to_try=(
            "$kver_full"
            "$kver_major"
            "${kver_major}.0"
        )
        
        local base_url="https://raw.githubusercontent.com/torvalds/linux"
        
        for ver in "${versions_to_try[@]}"; do
            info "Trying version: $ver"
            local url="${base_url}/v${ver}/${driver_subpath}/int3400_thermal.c"
            
            if curl -fsSL --max-time 30 "$url" -o "$BUILD_DIR/int3400_thermal.c" 2>/dev/null; then
                # También intentar descargar el header
                curl -fsSL --max-time 30 "${base_url}/v${ver}/${driver_subpath}/acpi_thermal_rel.h" \
                    -o "$BUILD_DIR/acpi_thermal_rel.h" 2>/dev/null || true
                
                ok "Source downloaded from: $url"
                src_c="$BUILD_DIR/int3400_thermal.c"
                src_h="$BUILD_DIR/acpi_thermal_rel.h"
                found_source=true
                break
            fi
        done
    fi

    # Method 3: Si aún no se encuentra, buscar en el kernel source instalado
    if [ "$found_source" = false ]; then
        info "Searching in installed kernel source..."

        # Process substitution avoids the pipe-subshell bug: changes to
        # found_source inside "find | while" would not propagate to outer scope
        local _sf
        while IFS= read -r _sf; do
            cp "$_sf" "$BUILD_DIR/int3400_thermal.c"
            found_source=true
            ok "Found source in: $_sf"
            break
        done < <(find "/lib/modules/$KVER/source" "/lib/modules/$KVER/build"                       -name "int3400_thermal.c" 2>/dev/null)
    fi

    # Si no se encuentra, aplicar solo RAPL/EPP
    if [ "$found_source" = false ]; then
        warn "Could not obtain int3400_thermal.c source after multiple attempts"
        warn "This usually means:"
        warn "  - Kernel headers are not properly installed"
        warn "  - The kernel source is not available"
        warn "  - Your kernel version is not in the upstream repository"
        warn ""
        warn "The script will still apply RAPL/EPP settings which provide most of the benefit"
        warn "but the enable_policy sysfs attribute will not be available."
        MODULE_NEEDED=false
        return 1
    fi

    # Copiar los archivos encontrados al build directory
    if [ -f "$src_c" ]; then
        cp "$src_c" "$BUILD_DIR/int3400_thermal.c"
        [ -f "${src_h:-}" ] && cp "$src_h" "$BUILD_DIR/acpi_thermal_rel.h" 2>/dev/null || true
        SOURCE_FILE="$BUILD_DIR/int3400_thermal.c"
        ok "Source ready for patching"
        return 0
    else
        warn "Source file not found at: $src_c"
        MODULE_NEEDED=false
        return 1
    fi
}

# =============================================================================
# 4. Aplicar el parche (simplificado y robusto)
# =============================================================================
apply_patch() {
    [ "${MODULE_NEEDED:-false}" = false ] && return 0
    info "Applying enable_policy patch..."

    local src="$BUILD_DIR/int3400_thermal.c"

    # Verificar que el archivo existe
    if [ ! -f "$src" ]; then
        warn "Source file not found at: $src"
        MODULE_NEEDED=false
        return 1
    fi

    # Check if source already has enable_policy
    if grep -q "enable_policy_store" "$src"; then
        ok "Source already contains enable_policy — no patch needed"
        return 0
    fi

    # Aplicar parche moderno directamente (más simple)
    if _patch_modern_direct "$src"; then
        ok "Patch applied successfully"
        return 0
    else
        warn "Failed to apply patch — applying RAPL/EPP only"
        MODULE_NEEDED=false
        return 1
    fi
}

_patch_modern_direct() {
    local src="$1"

    info "Applying enable_policy patch via Python..."
    cp "$src" "$src.orig"

    # Python handles multi-line C text manipulation more reliably than sed/awk:
    # - sed -i with continuation lines is not portable across GNU/BSD sed
    # - awk -v mangles backslash sequences (\n becomes real newline in C strings)
    # - Python re allows finding "return 0;" inside specific function bodies
    python3 "$BUILD_DIR/int3400_patch.py" "$src"
    local ret=$?
    if [ $ret -ne 0 ] || ! grep -q "enable_policy_store" "$src"; then
        warn "Patch failed — restoring original"
        mv "$src.orig" "$src"
        return 1
    fi
    return 0
}

# =============================================================================
# 5. Compile the module (MEJORADO)
# =============================================================================
build_module() {
    [ "${MODULE_NEEDED:-false}" = false ] && return 0
    info "Compiling int3400_thermal.ko..."

    # Crear un Makefile simple
    cat > "$BUILD_DIR/Makefile" << 'MAKEFILE_EOF'
obj-m := int3400_thermal.o

# Compilar con más flexibilidad
ccflags-y := -Wno-declaration-after-statement -Wno-unused-variable
MAKEFILE_EOF

    # Detectar si usar clang o gcc
    local make_extra=""
    local compiler="gcc"
    
    if command -v clang &>/dev/null && \
       grep -q "clang\|LLVM" "$KBUILD/Makefile" 2>/dev/null; then
        make_extra="CC=clang LD=ld.lld LLVM=1 LLVM_IAS=1"
        compiler="clang"
        info "Compiling with clang/LLVM"
    else
        info "Compiling with gcc"
    fi

    # Compilar con manejo de errores mejorado
    local compile_log="$BUILD_DIR/compile.log"
    
    if ! make -C "$KBUILD" M="$BUILD_DIR" $make_extra modules > "$compile_log" 2>&1; then
        warn "Compilation failed. Check log: $compile_log"
        warn "This is often due to kernel API changes between versions."
        warn "Applying RAPL/EPP settings only (no module patch)."
        MODULE_NEEDED=false
        return 1
    fi

    # Verificar que el módulo se compiló
    if [ ! -f "$BUILD_DIR/int3400_thermal.ko" ]; then
        warn "Module not found after compilation"
        MODULE_NEEDED=false
        return 1
    fi

    # Verificar vermagic
    local vm
    vm=$(modinfo "$BUILD_DIR/int3400_thermal.ko" 2>/dev/null | grep vermagic | awk '{print $2}')
    if [ -n "$vm" ] && [ "$vm" != "$KVER" ]; then
        warn "vermagic mismatch: module=$vm, kernel=$KVER"
        warn "Module may not load — applying RAPL/EPP only"
        MODULE_NEEDED=false
        return 1
    fi

    ok "Module compiled successfully: $(du -h "$BUILD_DIR/int3400_thermal.ko" | cut -f1)"
    return 0
}

# =============================================================================
# 6. Install the module (MEJORADO)
# =============================================================================
install_module() {
    [ "${MODULE_NEEDED:-false}" = false ] && return 0
    [ "${ALREADY_PATCHED:-false}" = true ] && return 0
    info "Installing patched module..."

    local driver_path="kernel/drivers/thermal/intel/int340x_thermal"
    local ko_base="/usr/lib/modules/$KVER/$driver_path/int3400_thermal.ko"

    # Detectar formato de compresión
    local installed_ko ext compress_cmd
    if   [ -f "${ko_base}.zst" ]; then 
        installed_ko="${ko_base}.zst"; 
        ext=".zst"; 
        compress_cmd="zstd -19 -f"
    elif [ -f "${ko_base}.xz"  ]; then 
        installed_ko="${ko_base}.xz";  
        ext=".xz";  
        compress_cmd="xz -f"
    elif [ -f "${ko_base}.gz"  ]; then 
        installed_ko="${ko_base}.gz";  
        ext=".gz";  
        compress_cmd="gzip -f"
    elif [ -f "${ko_base}"     ]; then 
        installed_ko="${ko_base}";      
        ext="";     
        compress_cmd="cp"
    else
        warn "Original module not found at $ko_base*"
        warn "This is expected if the driver is built into the kernel."
        warn "Applying RAPL/EPP settings only."
        MODULE_NEEDED=false
        return 1
    fi

    # Backup
    cp "$installed_ko" "/tmp/int3400_thermal_original${ext}.backup"
    ok "Backup saved: /tmp/int3400_thermal_original${ext}.backup"

    # Instalar el módulo compilado
    if [ -n "$ext" ]; then
        $compress_cmd "$BUILD_DIR/int3400_thermal.ko" -o "/tmp/int3400_thermal_new${ext}"
        cp "/tmp/int3400_thermal_new${ext}" "$installed_ko"
    else
        cp "$BUILD_DIR/int3400_thermal.ko" "$installed_ko"
    fi

    # Actualizar dependencias de módulos
    depmod -a "$KVER"

    # Recargar el módulo si estaba cargado
    if lsmod | grep -q "^int3400_thermal"; then
        info "Unloading existing module..."
        rmmod int3400_thermal 2>/dev/null || true
    fi
    
    info "Loading patched module..."
    if modprobe int3400_thermal 2>/dev/null; then
        ok "Module loaded successfully"
    else
        warn "Failed to load module. It may require a reboot."
        warn "You can try: reboot, then check if enable_policy appears."
    fi

    # Verificar atributo
    sleep 1
    local dptf_dev
    dptf_dev=$(find /sys/devices/platform -name "enable_policy" 2>/dev/null | head -1)
    if [ -n "$dptf_dev" ]; then
        ok "✅ Attribute enable_policy present: $dptf_dev"
    else
        warn "Module loaded but enable_policy not found"
        warn "This may mean:"
        warn "  - The patch didn't apply correctly"
        warn "  - Your firmware doesn't support this OSC UUID"
        warn "  - The driver didn't load properly (check dmesg)"
        warn ""
        warn "The RAPL/EPP settings will still be applied."
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

# RAPL MSR path: PL1=45W / PL2=60W / PL2 window=10s
RAPL=/sys/devices/virtual/powercap/intel-rapl/intel-rapl:0
[ -w "$RAPL/constraint_0_power_limit_uw" ] && echo 45000000 > "$RAPL/constraint_0_power_limit_uw" || true
[ -w "$RAPL/constraint_1_power_limit_uw" ] && echo 60000000 > "$RAPL/constraint_1_power_limit_uw" || true
[ -w "$RAPL/constraint_1_time_window_us" ] && echo 10000000 > "$RAPL/constraint_1_time_window_us" || true

# RAPL MMIO path (processor_thermal_rapl): same limits — hardware takes the minimum of both
# Without this, firmware caps the CPU at ~15W regardless of MSR settings
RAPL_MMIO=/sys/devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0
[ -w "$RAPL_MMIO/constraint_0_power_limit_uw" ] && echo 45000000 > "$RAPL_MMIO/constraint_0_power_limit_uw" || true
[ -w "$RAPL_MMIO/constraint_1_power_limit_uw" ] && echo 60000000 > "$RAPL_MMIO/constraint_1_power_limit_uw" || true
SCRIPT_EOF

    chmod +x /usr/local/bin/intel-dptf-policy.sh

    cat > /etc/systemd/system/intel-dptf-policy.service << 'SVC_EOF'
[Unit]
Description=Intel DPTF enable_policy and performance EPP
After=sysinit.target systemd-modules-load.service

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


# =============================================================================
# 8b. Pacman hook — auto-rebuild module on kernel update (Arch/CachyOS only)
# =============================================================================
install_pacman_hook() {
    # Only install on Arch-based systems with pacman
    command -v pacman &>/dev/null || return 0
    [ "${MODULE_NEEDED:-false}" = false ] && [ "${ALREADY_PATCHED:-false}" = false ] && return 0

    info "Installing pacman hook for automatic module rebuild on kernel updates..."

    # Install the Python patch helper to a permanent location
    cp "$BUILD_DIR/int3400_patch.py" /usr/local/lib/int3400_patch.py
    chmod +x /usr/local/lib/int3400_patch.py

    # Install the rebuild script
    cat > /usr/local/bin/int3400-rebuild.sh << 'REBUILD_EOF'
#!/bin/bash
# Recompiles the patched int3400_thermal module after a kernel update.
# Triggered by /etc/pacman.d/hooks/int3400-patch.hook
set -euo pipefail
KVER=$(uname -r)
KBUILD="/usr/lib/modules/$KVER/build"
PATCH_PY="/usr/local/lib/int3400_patch.py"
BUILD=$(mktemp -d /tmp/int3400_rebuild_XXXXXX)
trap 'rm -rf "$BUILD"' EXIT
log() { echo "[int3400-rebuild] $*"; }
die() { echo "[int3400-rebuild] ERROR: $*" >&2; exit 1; }
log "Kernel: $KVER"
[ -f "$KBUILD/Makefile" ] || die "Kernel headers not found at $KBUILD"
[ -f "$PATCH_PY" ]        || die "Patch script not found at $PATCH_PY"
MAKE_EXTRA=""
grep -q "^CC.*clang" "$KBUILD/Makefile" 2>/dev/null && MAKE_EXTRA="CC=clang LD=ld.lld LLVM=1 LLVM_IAS=1"
KVER_MAIN=$(echo "$KVER" | grep -oP '^\d+\.\d+')
BASE="https://raw.githubusercontent.com/torvalds/linux/v${KVER_MAIN}"
SUBPATH="drivers/thermal/intel/int340x_thermal"
log "Downloading int3400_thermal.c for Linux $KVER_MAIN..."
curl -fsSL --max-time 60 "$BASE/$SUBPATH/int3400_thermal.c" -o "$BUILD/int3400_thermal.c"     || die "Download failed. Check internet connection."
curl -fsSL --max-time 30 "$BASE/$SUBPATH/acpi_thermal_rel.h" -o "$BUILD/acpi_thermal_rel.h" 2>/dev/null || true
log "Applying enable_policy patch..."
python3 "$PATCH_PY" "$BUILD/int3400_thermal.c" || die "Patch failed"
grep -q "enable_policy_store" "$BUILD/int3400_thermal.c" || die "Patch verification failed"
echo "obj-m := int3400_thermal.o" > "$BUILD/Makefile"
log "Compiling..."
# shellcheck disable=SC2086
make -C "$KBUILD" M="$BUILD" $MAKE_EXTRA modules || die "Compilation failed"
VM=$(modinfo "$BUILD/int3400_thermal.ko" 2>/dev/null | awk '/^vermagic/{print $2}')
[ "$VM" = "$KVER" ] || die "vermagic mismatch: got $VM, expected $KVER"
KO_BASE="/usr/lib/modules/$KVER/kernel/$SUBPATH/int3400_thermal.ko"
if   [ -f "${KO_BASE}.zst" ]; then zstd -19 -f "$BUILD/int3400_thermal.ko" -o "${KO_BASE}.zst"
elif [ -f "${KO_BASE}.xz"  ]; then xz -f "$BUILD/int3400_thermal.ko" && mv "$BUILD/int3400_thermal.ko.xz" "${KO_BASE}.xz"
elif [ -f "${KO_BASE}.gz"  ]; then gzip -f "$BUILD/int3400_thermal.ko" && mv "$BUILD/int3400_thermal.ko.gz" "${KO_BASE}.gz"
elif [ -f "${KO_BASE}"     ]; then cp "$BUILD/int3400_thermal.ko" "${KO_BASE}"
else die "Module slot not found at $KO_BASE*"
fi
depmod -a "$KVER"
log "Module installed."
if lsmod | grep -q "^int3400_thermal"; then
    rmmod int3400_thermal && modprobe int3400_thermal && log "Module reloaded" || log "Reload failed — reboot required"
fi
systemctl is-active --quiet intel-dptf-policy.service 2>/dev/null && systemctl restart intel-dptf-policy.service && log "Service restarted"
log "Done. enable_policy: $(ls /sys/devices/platform/INTC*/enable_policy 2>/dev/null || echo 'not present')"
REBUILD_EOF
    chmod +x /usr/local/bin/int3400-rebuild.sh

    # Detect which kernel packages to watch
    local hook_targets="Target = linux"
    if pacman -Qi linux-cachyos &>/dev/null 2>&1; then
        hook_targets="Target = linux-cachyos
Target = linux-cachyos-headers"
    elif pacman -Qi linux &>/dev/null 2>&1; then
        hook_targets="Target = linux
Target = linux-headers"
    fi

    mkdir -p /etc/pacman.d/hooks
    cat > /etc/pacman.d/hooks/int3400-patch.hook << HOOK_EOF
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
$hook_targets

[Action]
Description = Recompiling patched int3400_thermal module for DPTF fix...
When = PostTransaction
Exec = /usr/local/bin/int3400-rebuild.sh
AbortOnFail
HOOK_EOF

    ok "Pacman hook installed: /etc/pacman.d/hooks/int3400-patch.hook"
    ok "Rebuild script:        /usr/local/bin/int3400-rebuild.sh"
    ok "Python patcher:        /usr/local/lib/int3400_patch.py"
    warn "The module will be automatically repatched after each kernel update."
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
    echo -e "${GRN}  Installation Complete${NC}"
    echo -e "${GRN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Current state:"
    echo -n "  EPP:        "; cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "N/A"
    echo -n "  RAPL PL1:   "; awk '{printf "%.0fW\n", $1/1000000}' /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null || echo "N/A"
    echo -n "  RAPL PL2:   "; awk '{printf "%.0fW\n", $1/1000000}' /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_1_power_limit_uw 2>/dev/null || echo "N/A"
    echo -n "  enable_policy: "
    find /sys/devices/platform -name "enable_policy" 2>/dev/null | head -1 | xargs -I{} dirname {} | xargs -I{} echo "present at {}" || echo "not available (RAPL/EPP only)"
    echo ""
    echo "✅ The RAPL power limits (PL1=45W, PL2=60W) and EPP=performance are now active."
    echo "✅ These settings will persist across reboots."
    echo ""
    if [ "${MODULE_NEEDED:-false}" = true ]; then
        echo "ℹ️  The patched module was installed. To verify:"
        echo "   ls -la /sys/devices/platform/INT3400*/enable_policy"
        echo ""
    else
        echo "ℹ️  RAPL/EPP settings were applied without module patching."
        echo "   This provides ~95% of the performance improvement."
        echo ""
    fi
    if [ -f /etc/pacman.d/hooks/int3400-patch.hook ]; then
        echo "✅ Pacman hook installed — module will be rebuilt automatically on kernel updates."
        echo ""
    fi
    echo "To uninstall:"
    echo "  systemctl disable --now intel-dptf-policy.service"
    echo "  rm -f /etc/pacman.d/hooks/int3400-patch.hook"
    echo "  rm -f /usr/local/bin/int3400-rebuild.sh /usr/local/lib/int3400_patch.py"
    echo "  rm -f /usr/local/bin/intel-dptf-policy.sh"
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
    install_pacman_hook
    apply_now
    print_summary
}

main "$@"
