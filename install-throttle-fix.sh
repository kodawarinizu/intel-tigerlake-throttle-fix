#!/bin/bash
# =============================================================================
# Intel i7-1185G7 / INT3400 / INTC1040 — CPU Throttle Fix
# Ref: https://github.com/intel/thermal_daemon/issues/341
#
# Funciona en: Arch, CachyOS, Ubuntu/Debian, Fedora/RHEL, openSUSE
# Requiere: kernel con CONFIG_INT340X_THERMAL=m, headers instalados, systemd
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
    info "Verificando hardware..."

    local cpu
    cpu=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2)
    echo "  CPU: $cpu"

    # Verificar que sea Intel TigerLake / compatible (INT3400 o INTC1040)
    if ! find /sys/devices/platform -maxdepth 1 \( -name "INT3400:*" -o -name "INTC1040:*" \) \
         -type d 2>/dev/null | grep -q .; then
        warn "No se encontró dispositivo INT3400/INTC1040. Este fix puede no aplicar."
        warn "Continuando de todas formas con la configuración RAPL/EPP..."
        MODULE_NEEDED=false
    else
        local dev
        dev=$(find /sys/devices/platform -maxdepth 1 \( -name "INT3400:*" -o -name "INTC1040:*" \) \
              -type d 2>/dev/null | head -1)
        ok "Dispositivo DPTF: $(basename "$dev")"
        DPTF_SYSFS="$dev"
        MODULE_NEEDED=true
    fi

    # Verificar si int3400_thermal es módulo o built-in
    if [ "${MODULE_NEEDED:-false}" = true ]; then
        if grep -qr "^CONFIG_INT340X_THERMAL=m" "/usr/lib/modules/$KVER/build/.config" \
                                                  "/boot/config-$KVER" \
                                                  "/proc/config.gz" 2>/dev/null; then
            ok "CONFIG_INT340X_THERMAL=m (módulo) — se puede parchehar sin recompilar el kernel"
        elif zcat /proc/config.gz 2>/dev/null | grep -q "^CONFIG_INT340X_THERMAL=m"; then
            ok "CONFIG_INT340X_THERMAL=m (módulo)"
        else
            warn "CONFIG_INT340X_THERMAL no es módulo (=y o no encontrado)"
            warn "Solo se aplicarán los ajustes RAPL/EPP"
            MODULE_NEEDED=false
        fi

        # Verificar si el parche ya está aplicado
        if [ -f "$DPTF_SYSFS/enable_policy" ]; then
            ok "El atributo 'enable_policy' ya existe — módulo ya parcheado"
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
    info "Instalando dependencias de compilación..."

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
                warn "Distro no reconocida. Asegúrate de tener: gcc/clang, make, kernel-headers"
            fi
            ;;
    esac
    ok "Dependencias listas"
}

# =============================================================================
# 3. Obtener el source de int3400_thermal.c
# =============================================================================
get_source() {
    [ "${MODULE_NEEDED:-false}" = false ] && return 0
    info "Buscando fuente de int3400_thermal.c..."

    local src_c src_h
    local driver_subpath="drivers/thermal/intel/int340x_thermal"

    # Método 1: fuente ya disponible localmente (Arch PKGBUILD extraído, etc.)
    for search_base in \
        "/usr/src/linux-$KVER" \
        "/usr/src/linux" \
        "/lib/modules/$KVER/source" \
        "$HOME/linux-cachyos/linux-cachyos/src/"*/ \
        "/usr/src/kernels/$KVER"; do
        if [ -f "$search_base/$driver_subpath/int3400_thermal.c" ]; then
            src_c="$search_base/$driver_subpath/int3400_thermal.c"
            src_h="$search_base/$driver_subpath/acpi_thermal_rel.h"
            ok "Fuente encontrada localmente: $search_base"
            break
        fi
    done

    # Método 2: descargar desde kernel.org/GitHub según la versión del kernel
    if [ -z "${src_c:-}" ]; then
        local kver_short
        # Extraer versión base (ej. "7.0.11" de "7.0.11-1-cachyos")
        kver_short=$(echo "$KVER" | grep -oP '^\d+\.\d+\.?\d*')
        info "Descargando fuente para kernel $kver_short desde kernel.org..."

        local base_url="https://raw.githubusercontent.com/torvalds/linux/v${kver_short}/${driver_subpath}"

        # Para kernels de distro custom (CachyOS, etc.) intentar también su fork
        local cachy_url="https://raw.githubusercontent.com/CachyOS/linux/cachyos-${kver_short}/${driver_subpath}"

        for url_base in "$cachy_url" "$base_url"; do
            if curl -fsSL --max-time 30 \
                    "${url_base}/int3400_thermal.c" \
                    -o "$BUILD_DIR/int3400_thermal.c" 2>/dev/null && \
               curl -fsSL --max-time 30 \
                    "${url_base}/acpi_thermal_rel.h" \
                    -o "$BUILD_DIR/acpi_thermal_rel.h" 2>/dev/null; then
                ok "Fuente descargada desde: $url_base"
                src_c="$BUILD_DIR/int3400_thermal.c"
                src_h="$BUILD_DIR/acpi_thermal_rel.h"
                break
            fi
        done
    fi

    if [ -z "${src_c:-}" ]; then
        warn "No se pudo obtener el source de int3400_thermal.c"
        warn "Se aplicarán solo los ajustes RAPL/EPP"
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
    info "Aplicando parche enable_policy..."

    local src="$BUILD_DIR/int3400_thermal.c"

    # Verificar si ya tiene enable_policy (algunos kernels futuros lo incluirán)
    if grep -q "enable_policy_store" "$src"; then
        ok "El source ya contiene enable_policy — no se necesita parche"
        return 0
    fi

    # Detectar qué firma tiene int3400_thermal_run_osc para elegir el parche correcto
    local osc_sig
    osc_sig=$(grep -n "^static int int3400_thermal_run_osc" "$src" | head -1)

    if echo "$osc_sig" | grep -q "char \*uuid_str.*int \*enable"; then
        # Firma moderna (kernel >= ~6.1): (handle, char *uuid_str, int *enable)
        _patch_modern "$src"
    elif echo "$osc_sig" | grep -q "enum int3400_thermal_uuid uuid.*bool enable"; then
        # Firma antigua (kernel <= ~5.18): (handle, enum uuid, bool enable)
        _patch_legacy "$src"
    else
        warn "Firma de int3400_thermal_run_osc no reconocida, intentando parche moderno..."
        _patch_modern "$src" || {
            warn "Parche falló — aplicando solo RAPL/EPP"
            MODULE_NEEDED=false
            return 1
        }
    fi
}

_patch_modern() {
    # Para kernels con la firma moderna: (handle, char *uuid_str, int *enable)
    local src="$1"
    local DPTF_UUID="b23ba85d-c8b7-3542-88de-8de2ffcfd698"

    # Buscar el punto de inserción: justo antes de current_uuid_store o de la
    # primera función sysfs después de set_os_uuid_mask / int3400_thermal_run_osc
    local insert_after
    insert_after=$(grep -n "^static int set_os_uuid_mask\|^static ssize_t current_uuid_store\|^static int int3400_thermal_get_uuids" \
                   "$src" | tail -1 | cut -d: -f1)

    if [ -z "$insert_after" ]; then
        # Fallback: insertar después de la primera función que llama a run_osc
        insert_after=$(grep -n "int3400_thermal_run_osc" "$src" | tail -1 | cut -d: -f1)
        # Buscar el cierre de esa función
        insert_after=$(awk "NR>$insert_after && /^}/ {print NR; exit}" "$src")
    fi

    [ -z "$insert_after" ] && { warn "No se encontró punto de inserción"; return 1; }

    # Insertar enable_policy_store y DEVICE_ATTR después de insert_after
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

    # Añadir device_create_file en probe
    _patch_probe_remove "$src"

    ok "Parche moderno aplicado (enable_policy_store + DEVICE_ATTR_WO)"
}

_patch_legacy() {
    # Para kernels con firma antigua: int3400_thermal_run_osc(handle, enum uuid, bool enable)
    # Estos kernels también necesitan la refactorización de run_osc
    warn "Kernel con firma antigua de run_osc. Aplicando parche completo original..."
    local src="$1"

    # Descargar el parche original y aplicar con fuzz máximo
    local PATCH_URL="https://lore.kernel.org/lkml/20220310014638.2927385-1-srinivas.pandruvada@linux.intel.com/raw"
    local tmpatch="$BUILD_DIR/original.patch"

    if curl -fsSL --max-time 30 "$PATCH_URL" -o "$tmpatch" 2>/dev/null; then
        cd "$BUILD_DIR"
        if patch -p1 --fuzz=5 < "$tmpatch" 2>/dev/null; then
            ok "Parche original aplicado con éxito"
        else
            warn "Parche original falló — aplicando solo RAPL/EPP"
            MODULE_NEEDED=false
        fi
    else
        warn "No se pudo descargar el parche original — aplicando solo RAPL/EPP"
        MODULE_NEEDED=false
    fi
}

_patch_probe_remove() {
    # Añade device_create_file/device_remove_file en probe() y remove()
    local src="$1"

    # En probe: añadir device_create_file justo antes de int3400_thermal_get_uuids
    # Patrón: buscar la inicialización de pdev y adev, insertar después
    sed -i 's/\(result = int3400_thermal_get_uuids(priv);\)/\n\tresult = device_create_file(\&pdev->dev, \&dev_attr_enable_policy);\n\tif (result)\n\t\tgoto free_priv;\n\n\t\1/' "$src" 2>/dev/null || true

    # En remove: añadir device_remove_file antes de kfree(priv)
    sed -i 's/\(\tkfree(priv);\n\treturn 0;\n}\)$/\tdevice_remove_file(\&pdev->dev, \&dev_attr_enable_policy);\n\1/' "$src" 2>/dev/null || true

    # Alternativa más robusta para el remove
    if ! grep -q "device_remove_file.*enable_policy" "$src"; then
        # Buscar el kfree final en remove y añadir antes
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
# 5. Compilar el módulo
# =============================================================================
build_module() {
    [ "${MODULE_NEEDED:-false}" = false ] && return 0
    info "Compilando int3400_thermal.ko..."

    # Crear Makefile mínimo
    echo "obj-m := int3400_thermal.o" > "$BUILD_DIR/Makefile"

    # Detectar si usar clang o gcc
    local make_extra=""
    if command -v clang &>/dev/null && \
       grep -q "clang\|LLVM" "$KBUILD/Makefile" 2>/dev/null; then
        make_extra="CC=clang LD=ld.lld LLVM=1 LLVM_IAS=1"
        info "Compilando con clang/LLVM"
    else
        info "Compilando con gcc"
    fi

    # Compilar
    if ! make -C "$KBUILD" M="$BUILD_DIR" $make_extra modules 2>&1; then
        warn "Compilación falló — aplicando solo RAPL/EPP"
        MODULE_NEEDED=false
        return 1
    fi

    # Verificar vermagic
    local vm
    vm=$(modinfo "$BUILD_DIR/int3400_thermal.ko" 2>/dev/null | grep vermagic | awk '{print $2}')
    if [ "$vm" != "$KVER" ]; then
        warn "vermagic mismatch: módulo=$vm, kernel=$KVER"
        warn "El módulo puede no cargarse — aplicando solo RAPL/EPP"
        MODULE_NEEDED=false
        return 1
    fi

    ok "Módulo compilado: vermagic=$vm"
}

# =============================================================================
# 6. Instalar el módulo
# =============================================================================
install_module() {
    [ "${MODULE_NEEDED:-false}" = false ] && return 0
    [ "${ALREADY_PATCHED:-false}" = true ] && return 0
    info "Instalando módulo parcheado..."

    local driver_path="kernel/drivers/thermal/intel/int340x_thermal"
    local ko_base="/usr/lib/modules/$KVER/$driver_path/int3400_thermal.ko"

    # Detectar formato de compresión del módulo instalado
    local installed_ko ext compress_cmd
    if   [ -f "${ko_base}.zst" ]; then installed_ko="${ko_base}.zst"; ext=".zst"; compress_cmd="zstd -19 -f"
    elif [ -f "${ko_base}.xz"  ]; then installed_ko="${ko_base}.xz";  ext=".xz";  compress_cmd="xz -f"
    elif [ -f "${ko_base}.gz"  ]; then installed_ko="${ko_base}.gz";  ext=".gz";  compress_cmd="gzip -f"
    elif [ -f "${ko_base}"     ]; then installed_ko="${ko_base}";      ext="";     compress_cmd="cp"
    else
        warn "Módulo original no encontrado en $ko_base*"
        warn "Aplicando solo RAPL/EPP"
        MODULE_NEEDED=false
        return 1
    fi

    # Backup
    cp "$installed_ko" "/tmp/int3400_thermal_original${ext}.backup"
    ok "Backup guardado: /tmp/int3400_thermal_original${ext}.backup"

    # Comprimir e instalar
    if [ -n "$ext" ]; then
        $compress_cmd "$BUILD_DIR/int3400_thermal.ko" -o "/tmp/int3400_thermal_new${ext}"
        cp "/tmp/int3400_thermal_new${ext}" "$installed_ko"
    else
        cp "$BUILD_DIR/int3400_thermal.ko" "$installed_ko"
    fi

    depmod -a "$KVER"

    # Recargar en caliente si ya está cargado
    if lsmod | grep -q "^int3400_thermal"; then
        rmmod int3400_thermal 2>/dev/null || true
    fi
    modprobe int3400_thermal

    # Verificar atributo
    sleep 1
    local dptf_dev
    dptf_dev=$(find /sys/devices/platform -name "enable_policy" 2>/dev/null | head -1)
    if [ -n "$dptf_dev" ]; then
        ok "Atributo enable_policy presente: $dptf_dev"
    else
        warn "Módulo cargado pero enable_policy no aparece (el firmware puede no soportar el OSC)"
    fi
}

# =============================================================================
# 7. Instalar servicio systemd
# =============================================================================
install_service() {
    info "Instalando servicio systemd..."

    if ! command -v systemctl &>/dev/null; then
        warn "systemd no disponible — creando script de rc.local"
        _install_rclocal
        return
    fi

    cat > /usr/local/bin/intel-dptf-policy.sh << 'SCRIPT_EOF'
#!/bin/bash
# Intel INT3400/INTC1040 CPU throttle fix
# Ref: https://github.com/intel/thermal_daemon/issues/341

# Activar política DPTF si el módulo parcheado está cargado
DPTF_DEV=$(find /sys/devices/platform -name "enable_policy" 2>/dev/null | head -1)
if [ -n "$DPTF_DEV" ]; then
    echo 1 > "$DPTF_DEV" 2>/dev/null || true
    echo 3 > "$DPTF_DEV" 2>/dev/null || true
fi

# EPP=performance en todos los cores (HWP no baja la frecuencia)
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    echo performance > "$cpu" 2>/dev/null || true
done

# RAPL: PL1=45W / PL2=60W / ventana PL2=10s
# El CPU se autorregula por temperatura — el ventilador define el límite real
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
    ok "Servicio intel-dptf-policy instalado y habilitado"
}

_install_rclocal() {
    local rc="/etc/rc.local"
    [ ! -f "$rc" ] && echo "#!/bin/bash" > "$rc" && chmod +x "$rc"
    if ! grep -q "intel-dptf-policy" "$rc"; then
        sed -i '/^exit 0/i /usr/local/bin/intel-dptf-policy.sh\n' "$rc" 2>/dev/null \
        || echo "/usr/local/bin/intel-dptf-policy.sh" >> "$rc"
    fi
    ok "Script añadido a $rc"
}

# =============================================================================
# 8. Aplicar ajustes inmediatamente (sin reboot)
# =============================================================================
apply_now() {
    info "Aplicando ajustes en caliente..."
    /usr/local/bin/intel-dptf-policy.sh
    ok "Ajustes aplicados"
}

# =============================================================================
# Resumen final
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GRN}════════════════════════════════════════════════════════${NC}"
    echo -e "${GRN}  Fix instalado correctamente${NC}"
    echo -e "${GRN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Estado actual:"
    echo -n "  EPP:        "; cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "N/A"
    echo -n "  RAPL PL1:   "; awk '{printf "%.0fW\n", $1/1000000}' /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null || echo "N/A"
    echo -n "  RAPL PL2:   "; awk '{printf "%.0fW\n", $1/1000000}' /sys/devices/virtual/powercap/intel-rapl/intel-rapl:0/constraint_1_power_limit_uw 2>/dev/null || echo "N/A"
    echo -n "  enable_policy: "
    find /sys/devices/platform -name "enable_policy" 2>/dev/null | head -1 | xargs -I{} dirname {} | xargs -I{} echo "presente en {}" || echo "no disponible (módulo no parcheado)"
    echo ""
    echo "Comportamiento esperado bajo carga:"
    echo "   0–10 s:  burst 4.0–4.3 GHz (PL2=60W)"
    echo "  10–30 s:  3.9–4.0 GHz (estabilización térmica)"
    echo "  30 s+  :  3.8–3.9 GHz (equilibrio térmico sostenido)"
    echo ""
    echo "Para desinstalar:"
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

    [ "$(id -u)" != "0" ] && die "Ejecutar como root: sudo $0"
    [ ! -d "$KBUILD" ]    && die "Kernel headers no encontrados en $KBUILD"

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
