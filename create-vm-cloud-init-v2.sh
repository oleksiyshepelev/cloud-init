#!/bin/bash

set -euo pipefail

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Función para mostrar mensajes
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# Inicialización de variables para evitar errores con set -u
resize_needed="false"
cleanup_temp="false"

# Limpieza de temporales al salir
cleanup() {
    if [[ "$cleanup_temp" == "true" && -n "${temp_image:-}" && -f "$temp_image" ]]; then
        rm -f "$temp_image"
        log "Archivo temporal eliminado"
    fi
}
trap cleanup EXIT

# Función para debug (opcional)
debug_storage() {
    if [[ "${DEBUG:-}" == "1" ]]; then
        echo -e "${YELLOW}[DEBUG] Salida de 'pvesm status':${NC}"
        pvesm status 2>&1 || echo "Error ejecutando pvesm status"
        echo -e "${YELLOW}[DEBUG] Almacenamientos detectados: ${#storages[@]}${NC}"
        for storage in "${storages[@]}"; do
            echo -e "${YELLOW}[DEBUG] - $storage${NC}"
        done
    fi
}

# Función para leer input con valor por defecto
read_input() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local input
    read -p "$prompt [$default]: " input
    eval "$var_name=\"\${input:-$default}\""
}

# Función para convertir tamaño a bytes
size_to_bytes() {
    local size="$1"
    size=$(echo "$size" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    if [[ $size =~ ^([0-9]+\.?[0-9]*)([kmgt]?)$ ]]; then
        local num="${BASH_REMATCH[1]}"
        local suffix="${BASH_REMATCH[2]}"
        case "$suffix" in
            "") echo "${num%.*}" ;;
            k) echo $(( ${num%.*} * 1024 )) ;;
            m) echo $(( ${num%.*} * 1024 * 1024 )) ;;
            g) echo $(( ${num%.*} * 1024 * 1024 * 1024 )) ;;
            t) echo $(( ${num%.*} * 1024 * 1024 * 1024 * 1024 )) ;;
        esac
    else
        error "Formato de tamaño inválido: $size (use formato: 10G, 512M, etc.)"
    fi
}

echo -e "${BLUE}=== 🛠️  Script para crear VM desde imagen cloud ===${NC}\n"

# Configuración con valores por defecto
read_input "ID de la VM" "9000" "vmid"
read_input "Nombre de la VM" "cloud-template" "vmname"

# Verificar si ya existe la VM
if qm status "$vmid" &>/dev/null; then
    error "Ya existe una VM con el ID $vmid"
fi

# Configuración del sistema
read_input "Tipo de OS (l26/w10/other)" "l26" "ostype"

# BIOS/UEFI
echo -e "\n${BLUE}Configuración de BIOS/UEFI:${NC}"
echo "  1) SeaBIOS (Legacy BIOS) - Compatibilidad máxima"
echo "  2) OVMF (UEFI) - Moderno, necesario para Secure Boot"
read_input "Seleccionar tipo de BIOS (1-2)" "1" "bios_choice"

case "$bios_choice" in
    1)
        bios_type="seabios"
        machine_type="pc"
        ;;
    2)
        bios_type="ovmf"
        machine_type="q35"
        if [ ! -f "/usr/share/pve-edk2-firmware/OVMF_CODE.fd" ]; then
            warn "OVMF no está instalado. Instalar con: apt install pve-edk2-firmware"
        fi
        ;;
    *)
        warn "Selección inválida, usando SeaBIOS por defecto"
        bios_type="seabios"
        machine_type="pc"
        ;;
esac

log "BIOS seleccionado: $bios_type, Máquina: $machine_type"

read_input "Tipo de CPU" "x86-64-v2-AES" "cputype"
read_input "Número de cores" "2" "cores"
read_input "Número de sockets" "1" "sockets"
read_input "Memoria RAM (MB)" "2048" "memory"

# Configuración de red
read_input "Bridge de red" "vmbr0" "bridge"
read_input "Modelo de NIC" "virtio" "nic_model"

# Consola serial
read_input "Habilitar consola serial (y/n)" "y" "enable_serial"

# Detectar imágenes disponibles
log "Buscando imágenes disponibles..."
mapfile -t images < <(find . -maxdepth 1 -type f \( -name "*.img" -o -name "*.qcow2" -o -name "*.raw" -o -name "*.vmdk" \) 2>/dev/null | sort)

if [ "${#images[@]}" -eq 0 ]; then
    error "No se encontraron imágenes compatibles (.img, .qcow2, .raw, .vmdk)"
fi

echo -e "\n${BLUE}Imágenes encontradas:${NC}"
for i in "${!images[@]}"; do
    filename=$(basename "${images[$i]}")
    size=$(du -h "${images[$i]}" | cut -f1)
    if command -v qemu-img &> /dev/null; then
        img_info=$(qemu-img info "${images[$i]}" 2>/dev/null)
        img_format=$(echo "$img_info" | grep "file format:" | awk '{print $3}')
        virtual_size=$(echo "$img_info" | grep "virtual size:" | awk '{print $3}')
        echo "  $((i+1))) $filename ($size en disco, $virtual_size virtual, formato: $img_format)"
    else
        echo "  $((i+1))) $filename ($size)"
    fi
done

read_input "Seleccionar imagen (número)" "1" "img_choice"
img_index=$((img_choice - 1))

if [[ "$img_index" -lt 0 || "$img_index" -ge "${#images[@]}" ]]; then
    error "Selección de imagen inválida"
fi

image="${images[$img_index]}"
log "Imagen seleccionada: $(basename "$image")"

# Redimensionar disco
if command -v qemu-img &> /dev/null; then
    img_info=$(qemu-img info "$image" 2>/dev/null)
    current_size=$(echo "$img_info" | grep "virtual size:" | awk '{print $3}')
    echo -e "\n${BLUE}Redimensionar disco:${NC}"
    echo "Tamaño actual: $current_size"
    read_input "¿Redimensionar disco? (y/n)" "n" "resize_disk"
    if [[ "$resize_disk" =~ ^[Yy]$ ]]; then
        while true; do
            read_input "Nuevo tamaño (ej: 10G, 20G, 50G)" "20G" "new_size"
            current_bytes=$(echo "$img_info" | grep "virtual size:" | sed -n 's/.*(\([0-9,]*\) bytes).*/\1/p' | tr -d ',')
            if [ -z "$current_bytes" ] || [ "$current_bytes" = "0" ]; then
                current_bytes=$(echo "$img_info" | grep -o '[0-9,]* bytes' | head -1 | tr -d ', bytes')
            fi
            if [ -z "$current_bytes" ] || [ "$current_bytes" = "0" ]; then
                warn "No se pudo determinar el tamaño actual exacto. Procediendo sin validación."
                resize_needed="true"
                break
            else
                new_bytes=$(size_to_bytes "$new_size")
                log "Comparando: actual=$current_bytes bytes vs nuevo=$new_bytes bytes"
                if [ "$new_bytes" -le "$current_bytes" ]; then
                    echo -e "${YELLOW}El nuevo tamaño ($new_size = $new_bytes bytes) debe ser mayor que el actual ($current_bytes bytes)${NC}"
                    echo "Opciones:"
                    echo "  1) Introducir otro tamaño"
                    echo "  3) Cancelar redimensionado"
                    read_input "Seleccionar opción (1-3)" "1" "size_choice"
                    case "$size_choice" in
                        1) continue ;;
                        3) resize_disk="n"; break ;;
                        *) warn "Opción inválida, volviendo a pedir tamaño..."; continue ;;
                    esac
                else
                    resize_needed="true"
                    break
                fi
            fi
        done
    fi
else
    warn "qemu-img no disponible, no se puede redimensionar"
    resize_disk="n"
fi

# Obtener almacenamientos
log "Obteniendo almacenamientos disponibles..."
if command -v pvesm &>/dev/null; then
    mapfile -t storages < <(pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | sort)
    if [ "${#storages[@]}" -eq 0 ]; then
        warn "No se encontraron almacenamientos con 'pvesm status', usando valores por defecto"
        storages=("local" "local-lvm")
    fi
else
    error "Comando 'pvesm' no encontrado. ¿Estás ejecutando esto en un nodo Proxmox?"
fi

debug_storage

if [ "${#storages[@]}" -eq 0 ]; then
    error "No hay almacenamientos configurados"
fi

echo -e "\n${BLUE}Almacenamientos disponibles:${NC}"
for i in "${!storages[@]}"; do
    echo "  $((i+1))) ${storages[$i]}"
done

read_input "Seleccionar almacenamiento (número)" "1" "storage_choice"
storage_index=$((storage_choice - 1))

if [[ "$storage_index" -lt 0 || "$storage_index" -ge "${#storages[@]}" ]]; then
    error "Selección de almacenamiento inválida"
fi

storage="${storages[$storage_index]}"

# Controlador SCSI
read_input "Controlador SCSI (virtio-scsi-single/virtio-scsi-pci/lsi)" "virtio-scsi-single" "scsihw"

# Crear VM (sin eval, usando array para mayor seguridad)
create_cmd=(qm create "$vmid"
    --name "$vmname"
    --ostype "$ostype"
    --cpu "cputype=$cputype"
    --cores "$cores"
    --sockets "$sockets"
    --memory "$memory"
    --net0 "$nic_model,bridge=$bridge"
    --scsihw "$scsihw"
    --machine "$machine_type"
)
if [ "$bios_type" = "ovmf" ]; then
    create_cmd+=(--bios ovmf --efidisk0 "$storage:1,efitype=4m,pre-enrolled-keys=0")
fi
if [[ "$enable_serial" =~ ^[Yy]$ ]]; then
    create_cmd+=(--serial0 socket --vga serial0)
fi

"${create_cmd[@]}" || error "Falló la creación de la VM"

# Redimensionar imagen antes de importar
if [[ "$resize_disk" =~ ^[Yy]$ && "$resize_needed" == "true" ]]; then
    log "Redimensionando imagen a $new_size..."
    temp_image="/tmp/$(basename "$image").resized"
    cp "$image" "$temp_image" || error "No se pudo crear copia temporal"
    if qemu-img resize "$temp_image" "$new_size"; then
        success "Imagen redimensionada exitosamente a $new_size"
        image="$temp_image"
        cleanup_temp="true"
    else
        error "Falló el redimensionado de la imagen"
    fi
fi

# Importar disco
log "Importando disco desde $(basename "$image")..."
echo -e "\n${BLUE}Formato del disco en Proxmox:${NC}"
echo "  1) raw - Mejor rendimiento, más espacio"
echo "  2) qcow2 - Snapshots, thin provisioning, menos espacio"
read_input "Seleccionar formato final (1-2)" "1" "format_choice"

case "$format_choice" in
    1) final_format="raw" ;;
    2) final_format="qcow2" ;;
    *) warn "Selección inválida, usando raw por defecto"; final_format="raw" ;;
esac

case "${image,,}" in
    *.img|*.raw) source_format="raw" ;;
    *.qcow2) source_format="qcow2" ;;
    *.vmdk) source_format="vmdk" ;;
    *)
        if command -v qemu-img &> /dev/null; then
            detected_format=$(qemu-img info "$image" 2>/dev/null | grep "file format:" | awk '{print $3}')
            source_format="${detected_format:-raw}"
            log "Formato origen detectado automáticamente: $source_format"
        else
            source_format="raw"
            warn "No se pudo detectar el formato origen, usando RAW por defecto"
        fi
        ;;
esac

log "Importando disco: $source_format → $final_format"
if ! qm importdisk "$vmid" "$image" "$storage" --format "$final_format"; then
    error "Falló la importación del disco"
fi

# Asociar disco importado
log "Buscando disco importado en configuración unused..."
sleep 1
unused_line=$(qm config "$vmid" | grep "^unused" | head -1)
if [ -n "$unused_line" ]; then
    unused_key=$(echo "$unused_line" | cut -d: -f1)
    log "Disco encontrado como: $unused_key"
    log "Moviendo $unused_key a scsi0..."
    disk_full_id=$(echo "$unused_line" | cut -d: -f2- | xargs)
    if qm set "$vmid" --scsi0 "$disk_full_id"; then
        success "Disco asociado con ID completo"
        qm set "$vmid" --delete "$unused_key" 2>/dev/null || true
    elif qm set "$vmid" --scsi0 "$unused_key"; then
        success "Disco asociado usando referencia unused"
    elif qm set "$vmid" --scsi0 "${storage}:vm-${vmid}-disk-0"; then
        success "Disco asociado con formato estándar"
        qm set "$vmid" --delete "$unused_key" 2>/dev/null || true
    else
        error "Todos los métodos de asociación fallaron. 
Puedes asociar el disco manualmente con:
  qm set $vmid --scsi0 $unused_key
O desde la interfaz web de Proxmox:
  Hardware → $unused_key → Edit → Seleccionar SCSI0"
    fi
else
    log "No se encontró disco unused, verificando si ya está asociado..."
    if qm config "$vmid" | grep -q "^scsi0:"; then
        success "El disco ya está asociado correctamente"
    else
        disk_id="${storage}:vm-${vmid}-disk-0"
        log "Intentando asociar con ID estándar: $disk_id"
        if qm set "$vmid" --scsi0 "$disk_id"; then
            success "Disco asociado correctamente"
        else
            error "No se pudo asociar el disco. Verifica manualmente con: qm config $vmid"
        fi
    fi
fi

# Configurar arranque
read_input "Configurar como disco de arranque (y/n)" "y" "set_boot"
if [[ "$set_boot" =~ ^[Yy]$ ]]; then
    log "Configurando orden de arranque..."
    qm set "$vmid" --boot order=scsi0
fi

# Cloud-init (opcional)
read_input "Añadir soporte para Cloud-init (y/n)" "y" "add_cloudinit"
if [[ "$add_cloudinit" =~ ^[Yy]$ ]]; then
    log "Añadiendo Cloud-init..."
    if ! qm config "$vmid" | grep -q "^ide2:"; then
        qm set "$vmid" --ide2 "$storage:cloudinit"
    else
        warn "Ya existe un disco en ide2, omitiendo creación de cloudinit."
    fi
    qm set "$vmid" --citype nocloud
fi

# Resumen final
echo -e "\n${GREEN}✅ VM creada exitosamente!${NC}"
echo -e "${BLUE}Detalles de la VM:${NC}"
echo "  - ID: $vmid"
echo "  - Nombre: $vmname"
echo "  - Imagen: $(basename "$image")"
echo "  - Almacenamiento: $storage"
echo "  - CPU: $cores cores, $sockets sockets ($cputype)"
echo "  - RAM: ${memory}MB"
echo "  - BIOS: $bios_type"
echo "  - Máquina: $machine_type"
echo "  - Formato disco: $final_format"
if [[ "$resize_disk" =~ ^[Yy]$ && "$resize_needed" == "true" ]]; then
    echo "  - Disco redimensionado a: $new_size"
fi

echo -e "\n${BLUE}Discos creados:${NC}"
echo "  - scsi0: Disco principal del sistema ($final_format)"
if [ "$bios_type" = "ovmf" ]; then
    echo "  - efidisk0: Disco EFI para arranque UEFI (~1MB)"
fi
if [[ "$add_cloudinit" =~ ^[Yy]$ ]]; then
    echo "  - ide2: Disco Cloud-init (~4MB)"
fi

echo -e "\n${BLUE}Comandos útiles:${NC}"
echo "  - Ver configuración: qm config $vmid"
echo "  - Iniciar VM: qm start $vmid"
echo "  - Convertir en template: qm template $vmid"
echo "  - Consola: qm monitor $vmid"
if [[ "$enable_serial" =~ ^[Yy]$ ]]; then
    echo "  - Consola serial: qm terminal $vmid"
fi

# Comprobación de estado final
if qm status "$vmid" &>/dev/null; then
    success "¡VM lista para usar!"
else
    error "La VM no se encuentra en el sistema. Revisa los logs de Proxmox para más detalles."
    