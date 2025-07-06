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

## MEJORA: Añadir un trap para la limpieza automática de archivos temporales al salir.
# Esto asegura que si el script falla en cualquier momento, el archivo temporal se elimina.
cleanup() {
    if [[ "${cleanup_temp:-}" == "true" && -n "${temp_image:-}" && -f "${temp_image}" ]]; then
        log "Ejecutando limpieza automática..."
        rm -f "$temp_image"
        success "Archivo temporal eliminado."
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
    
    read -p "$prompt [$default]: " input
    eval "$var_name=\"\${input:-$default}\""
}

## MEJORA: La función ahora usa 'awk' para soportar números decimales.
# La aritmética de Bash ($((...))) no soporta punto flotante, lo que causaba errores.
size_to_bytes() {
    local size="$1"
    size=$(echo "$size" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    
    if [[ $size =~ ^([0-9]+\.?[0-9]*)([kmgt]?)$ ]]; then
        local num="${BASH_REMATCH[1]}"
        local suffix="${BASH_REMATCH[2]}"
        
        # Usar awk para manejar decimales de forma segura
        awk -v num="$num" -v suffix="$suffix" 'BEGIN {
            mult = 1;
            if (suffix == "k") mult = 1024;
            if (suffix == "m") mult = 1024^2;
            if (suffix == "g") mult = 1024^3;
            if (suffix == "t") mult = 1024^4;
            # printf "%.0f" para redondear al entero más cercano
            printf "%.0f\n", num * mult;
        }'
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

echo -e "\n${BLUE}Configuración de BIOS/UEFI:${NC}"
echo "  1) SeaBIOS (Legacy BIOS) - Compatibilidad máxima"
echo "  2) OVMF (UEFI) - Moderno, necesario para Secure Boot"
read_input "Seleccionar tipo de BIOS (1-2)" "1" "bios_choice"

case "$bios_choice" in
    1) bios_type="seabios"; machine_type="pc" ;;
    2)
        bios_type="ovmf"
        machine_type="q35"
        if [ ! -f "/usr/share/pve-edk2-firmware/OVMF_CODE.fd" ]; then
            warn "OVMF no está instalado. Instalar con: apt install pve-edk2-firmware"
        fi
        ;;
    *)
        warn "Selección inválida, usando SeaBIOS por defecto"
        bios_type="seabios"; machine_type="pc"
        ;;
esac

log "BIOS seleccionado: $bios_type, Máquina: $machine_type"

read_input "Tipo de CPU" "x86-64-v2-AES" "cputype"
read_input "Número de cores" "2" "cores"
read_input "Número de sockets" "1" "sockets"
read_input "Memoria RAM (MB)" "2048" "memory"
read_input "Bridge de red" "vmbr0" "bridge"
read_input "Modelo de NIC" "virtio" "nic_model"
read_input "Habilitar consola serial (y/n)" "y" "enable_serial"

log "Buscando imágenes disponibles..."
mapfile -t images < <(find . -maxdepth 1 -type f \( -name "*.img" -o -name "*.qcow2" -o -name "*.raw" -o -name "*.vmdk" \) 2>/dev/null | sort)

if [ ${#images[@]} -eq 0 ]; then
    error "No se encontraron imágenes compatibles (.img, .qcow2, .raw, .vmdk)"
fi

echo -e "\n${BLUE}Imágenes encontradas:${NC}"
for i in "${!images[@]}"; do
    filename=$(basename "${images[$i]}")
    size=$(du -h "${images[$i]}" | cut -f1)
    if command -v qemu-img &> /dev/null; then
        img_info=$(qemu-img info "${images[$i]}" 2>/dev/null)
        img_format=$(echo "$img_info" | grep "file format:" | awk '{print $3}')
        virtual_size=$(echo "$img_info" | grep "virtual size:" | awk '{print $3$4}')
        echo "  $((i+1))) $filename ($size en disco, $virtual_size virtual, formato: $img_format)"
    else
        echo "  $((i+1))) $filename ($size)"
    fi
done

read_input "Seleccionar imagen (número)" "1" "img_choice"
img_index=$((img_choice - 1))

if [[ $img_index -lt 0 || $img_index -ge ${#images[@]} ]]; then
    error "Selección de imagen inválida"
fi

image="${images[$img_index]}"
log "Imagen seleccionada: $(basename "$image")"

if command -v qemu-img &> /dev/null; then
    img_info=$(qemu-img info "$image" 2>/dev/null)
    current_size_human=$(echo "$img_info" | grep "virtual size:" | awk '{print $3$4}')
    
    echo -e "\n${BLUE}Redimensionar disco:${NC}"
    echo "Tamaño actual: $current_size_human"
    read_input "¿Redimensionar disco? (y/n)" "n" "resize_disk"
    
    if [[ "$resize_disk" =~ ^[Yy]$ ]]; then
        while true; do
            read_input "Nuevo tamaño (ej: 10G, 20G, 50G)" "20G" "new_size"
            
            ## MEJORA: Usar jq si está disponible para un parseo robusto y seguro del tamaño.
            if command -v jq &> /dev/null; then
                log "Usando jq para obtener el tamaño del disco."
                current_bytes=$(qemu-img info --output=json "$image" | jq '.["virtual-size"]' || echo "0")
            else
                warn "jq no está instalado. Usando método de parseo de texto (menos robusto)."
                current_bytes=$(echo "$img_info" | grep "virtual size:" | sed -n 's/.*(\([0-9]*\) bytes).*/\1/p' | tr -d ',')
            fi
            
            if [ -z "$current_bytes" ] || [ "$current_bytes" = "0" ]; then
                warn "No se pudo determinar el tamaño actual exacto. Procediendo sin validación."
                resize_needed="true"; break
            else
                new_bytes=$(size_to_bytes "$new_size")
                log "Comparando: actual=$current_bytes bytes vs nuevo=$new_bytes bytes"
                
                if [ "$new_bytes" -le "$current_bytes" ]; then
                    echo -e "${YELLOW}El nuevo tamaño ($new_size = $new_bytes bytes) debe ser mayor que el actual ($current_bytes bytes)${NC}"
                    echo "Opciones: 1) Introducir otro tamaño, 2) Continuar de todas formas, 3) Cancelar redimensionado"
                    read_input "Seleccionar opción (1-3)" "1" "size_choice"
                    case "$size_choice" in
                        1) continue ;;
                        2) resize_needed="true"; break ;;
                        3) resize_disk="n"; break ;;
                        *) warn "Opción inválida, volviendo a pedir tamaño..."; continue ;;
                    esac
                else
                    resize_needed="true"; break
                fi
            fi
        done
    fi
else
    warn "qemu-img no disponible, no se puede redimensionar"; resize_disk="n"
fi

log "Obteniendo almacenamientos disponibles..."
if command -v pvesm &>/dev/null; then
    mapfile -t storages < <(pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | sort)
    
    ## MEJORA: El método de fallback ahora parsea /etc/pve/storage.cfg, es más fiable.
    if [ ${#storages[@]} -eq 0 ]; then
        warn "No se encontraron almacenamientos con 'pvesm status', intentando leer /etc/pve/storage.cfg..."
        mapfile -t storages < <(grep -E '^(dir|lvmthin|zfspool|nfs|cifs):' /etc/pve/storage.cfg 2>/dev/null | cut -d' ' -f2 | sort)
    fi
else
    error "Comando 'pvesm' no encontrado. ¿Estás ejecutando esto en un nodo Proxmox?"
fi

# Si todo falla, usar valores por defecto
if [ ${#storages[@]} -eq 0 ]; then
    warn "No se pudo detectar almacenamientos. Usando valores por defecto (local, local-lvm)."
    storages=("local" "local-lvm")
fi

debug_storage

if [ ${#storages[@]} -eq 0 ]; then
    error "No hay almacenamientos configurados."
fi

echo -e "\n${BLUE}Almacenamientos disponibles:${NC}"
for i in "${!storages[@]}"; do
    echo "  $((i+1))) ${storages[$i]}"
done

read_input "Seleccionar almacenamiento (número)" "1" "storage_choice"
storage_index=$((storage_choice - 1))

if [[ $storage_index -lt 0 || $storage_index -ge ${#storages[@]} ]]; then
    error "Selección de almacenamiento inválida"
fi
storage="${storages[$storage_index]}"

read_input "Controlador SCSI (virtio-scsi-single/virtio-scsi-pci/lsi)" "virtio-scsi-single" "scsihw"

## MEJORA: Usar un array para construir el comando de forma segura y evitar 'eval'.
# Esto es más robusto y previene problemas de inyección de comandos o errores con espacios.
log "Creando VM con ID $vmid..."
cmd_args=(
    "qm" "create" "$vmid"
    "--name" "$vmname"
    "--ostype" "$ostype"
    "--cpu" "cputype=$cputype"
    "--cores" "$cores"
    "--sockets" "$sockets"
    "--memory" "$memory"
    "--net0" "$nic_model,bridge=$bridge"
    "--scsihw" "$scsihw"
    "--machine" "$machine_type"
)

if [ "$bios_type" = "ovmf" ]; then
    cmd_args+=("--bios" "ovmf")
    cmd_args+=("--efidisk0" "$storage:1,efitype=4m,pre-enrolled-keys=0")
fi

if [[ "$enable_serial" =~ ^[Yy]$ ]]; then
    cmd_args+=("--serial0" "socket" "--vga" "serial0")
fi

log "Ejecutando: ${cmd_args[*]}"
if ! "${cmd_args[@]}"; then
    error "Falló la creación de la VM"
fi

if [[ "${resize_disk:-n}" =~ ^[Yy]$ && "${resize_needed:-false}" == "true" ]]; then
    log "Redimensionando imagen a $new_size..."
    temp_image="/tmp/$(basename "$image")-resized-$$"
    cp "$image" "$temp_image" || error "No se pudo crear copia temporal"
    
    if qemu-img resize "$temp_image" "$new_size"; then
        success "Imagen redimensionada exitosamente a $new_size"
        image="$temp_image"
        cleanup_temp="true" # Marcar para limpieza con el trap
    else
        error "Falló el redimensionado de la imagen"
    fi
fi

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

log "Importando disco con formato final $final_format"
if ! qm importdisk "$vmid" "$image" "$storage" --format "$final_format"; then
    error "Falló la importación del disco"
fi

# El script ya no necesita limpiar el archivo temporal aquí, el trap lo hará al final.

log "Asociando disco importado..."
sleep 1 # Pausa para que Proxmox actualice la configuración

unused_line=$(qm config "$vmid" | grep "^unused" | head -1)

if [ -n "$unused_line" ]; then
    unused_disk=$(echo "$unused_line" | cut -d: -f2- | xargs)
    log "Disco encontrado como 'unused': $unused_disk"
    log "Asociando disco a scsi0..."
    
    if ! qm set "$vmid" --scsi0 "$unused_disk"; then
        error "Falló la asociación del disco. Inténtalo manualmente desde la UI de Proxmox."
    fi
else
    log "No se encontró disco 'unused', verificando si ya está en scsi0..."
    if ! qm config "$vmid" | grep -q "^scsi0:"; then
        error "No se pudo encontrar ni asociar el disco importado. Verifica la configuración de la VM."
    fi
fi

success "Disco asociado correctamente a scsi0."

read_input "Configurar como disco de arranque (y/n)" "y" "set_boot"
if [[ "$set_boot" =~ ^[Yy]$ ]]; then
    log "Configurando orden de arranque..."
    qm set "$vmid" --boot order=scsi0
fi

read_input "Añadir soporte para Cloud-init (y/n)" "y" "add_cloudinit"
if [[ "$add_cloudinit" =~ ^[Yy]$ ]]; then
    log "Añadiendo Cloud-init..."
    qm set "$vmid" --ide2 "$storage:cloudinit"
fi

# Resumen final
echo -e "\n${GREEN}✅ VM creada exitosamente!${NC}"
echo -e "${BLUE}Detalles de la VM:${NC}"
echo "  - ID: $vmid, Nombre: $vmname"
echo "  - Imagen: $(basename "${image original}")"
echo "  - Almacenamiento: $storage, Formato: $final_format"
echo "  - CPU: $cores cores, $sockets sockets ($cputype), RAM: ${memory}MB"
echo "  - BIOS: $bios_type, Máquina: $machine_type"
if [[ "${resize_disk:-n}" =~ ^[Yy]$ && "${resize_needed:-false}" == "true" ]]; then
    echo "  - Disco redimensionado a: $new_size"
fi

echo -e "\n${BLUE}Discos creados:${NC}"
echo "  - scsi0: Disco principal del sistema"
if [ "$bios_type" = "ovmf" ]; then echo "  - efidisk0: Disco EFI para arranque UEFI"; fi
if [[ "$add_cloudinit" =~ ^[Yy]$ ]]; then echo "  - ide2: Disco Cloud-init"; fi

echo -e "\n${BLUE}Comandos útiles:${NC}"
echo "  - Ver configuración: qm config $vmid"
echo "  - Iniciar VM: qm start $vmid"
echo "  - Convertir en template: qm template $vmid"
if [[ "$enable_serial" =~ ^[Yy]$ ]]; then echo "  - Consola serial: qm terminal $vmid"; fi

success "¡VM lista para usar!"