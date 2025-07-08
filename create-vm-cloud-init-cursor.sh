#!/bin/bash

set -euo pipefail

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# === NUEVO: Variables globales para dry-run y log ===
DRY_RUN=0
LOG_FILE="/var/log/proxmox-vm-create.log"

# Función para mostrar mensajes
log() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# Función para loguear en archivo
log_to_file() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# Función para ejecutar comandos (respeta dry-run)
run_cmd() {
    local cmd="$1"
    if [[ "$DRY_RUN" == "1" ]]; then
        warn "[DRY-RUN] $cmd"
        log_to_file "[DRY-RUN] $cmd"
    else
        log_to_file "[RUN] $cmd"
        eval "$cmd"
    fi
}

# === NUEVO: Procesar argumentos para dry-run y ayuda ===
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --help|-h)
            echo -e "\nUso: $0 [--dry-run] [--help]\n"
            echo "  --dry-run   Simula la ejecución, solo muestra los comandos."
            echo "  --help      Muestra esta ayuda."
            exit 0
            ;;
    esac
    # No shift aquí para no perder argumentos de usuario
    # (el script es interactivo, no usa más args)
done

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

# *** NUEVA SECCIÓN: Tipo de BIOS ***
echo -e "\n${BLUE}Configuración de BIOS/UEFI:${NC}"
echo "  1) OVMF (UEFI) - Moderno, necesario para Secure Boot"
echo "  2) SeaBIOS (Legacy BIOS) - Compatibilidad máxima"
read_input "Seleccionar tipo de BIOS (1-2)" "1" "bios_choice"

case "$bios_choice" in
    1)
        bios_type="ovmf"
        machine_type="q35"
        # Verificar si existe el archivo OVMF
        if [ ! -f "/usr/share/pve-edk2-firmware/OVMF_CODE.fd" ]; then
            warn "OVMF no está instalado. Instalar con: apt install pve-edk2-firmware"
        fi
        ;;
    2)
        bios_type="seabios"
        machine_type="pc"
        ;;
    *)
        warn "Selección inválida, usando OVMF (UEFI) por defecto"
        bios_type="ovmf"
        machine_type="q35"
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

if [ ${#images[@]} -eq 0 ]; then
    error "No se encontraron imágenes compatibles (.img, .qcow2, .raw, .vmdk)"
fi

echo -e "\n${BLUE}Imágenes encontradas:${NC}"
for i in "${!images[@]}"; do
    filename=$(basename "${images[$i]}")
    size=$(du -h "${images[$i]}" | cut -f1)
    # Mostrar información adicional de la imagen si qemu-img está disponible
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

if [[ $img_index -lt 0 || $img_index -ge ${#images[@]} ]]; then
    error "Selección de imagen inválida"
fi

image="${images[$img_index]}"
log "Imagen seleccionada: $(basename "$image")"

# Obtener almacenamientos
log "Obteniendo almacenamientos disponibles..."

# Intentar diferentes métodos para obtener almacenamientos
if command -v pvesm &>/dev/null; then
    mapfile -t storages < <(pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | sort)
    
    # Si no encuentra almacenamientos, intentar método alternativo
    if [ ${#storages[@]} -eq 0 ]; then
        warn "No se encontraron almacenamientos con 'pvesm status', intentando método alternativo..."
        mapfile -t storages < <(ls /etc/pve/storage.cfg 2>/dev/null | xargs grep -l ":" | head -10 2>/dev/null || echo "local")
        
        # Si tampoco funciona, usar valores comunes por defecto
        if [ ${#storages[@]} -eq 0 ]; then
            warn "Usando almacenamientos por defecto"
            storages=("local" "local-lvm")
        fi
    fi
else
    error "Comando 'pvesm' no encontrado. ¿Estás ejecutando esto en un nodo Proxmox?"
fi

# Debug opcional
debug_storage

if [ ${#storages[@]} -eq 0 ]; then
    error "No hay almacenamientos configurados"
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

# Controlador SCSI
read_input "Controlador SCSI (virtio-scsi-single/virtio-scsi-pci/lsi)" "virtio-scsi-single" "scsihw"

# Crear VM
log "Creando VM con ID $vmid..."

create_cmd="qm create $vmid \
    --name \"$vmname\" \
    --ostype \"$ostype\" \
    --cpu \"cputype=$cputype\" \
    --cores $cores \
    --sockets $sockets \
    --memory $memory \
    --net0 \"$nic_model,bridge=$bridge\" \
    --scsihw \"$scsihw\" \
    --machine \"$machine_type\""

# Configurar BIOS
if [ "$bios_type" = "ovmf" ]; then
    create_cmd+=" --bios ovmf"
    # Añadir EFI disk para UEFI
    create_cmd+=" --efidisk0 \"$storage:1,efitype=4m,pre-enrolled-keys=0\""
fi

# Agregar consola serial si está habilitada
if [[ "$enable_serial" =~ ^[Yy]$ ]]; then
    create_cmd+=" --serial0 socket --vga serial0"
fi

# Ejemplo de uso de run_cmd en vez de eval directo:
# eval "$create_cmd" || error "Falló la creación de la VM"
run_cmd "$create_cmd" || error "Falló la creación de la VM"

# Importar disco - CORRECCIÓN del problema original
log "Importando disco desde $(basename "$image")..."

# *** NUEVA SECCIÓN: Selección de formato de salida ***
echo -e "\n${BLUE}Formato del disco en Proxmox:${NC}"
echo "  1) qcow2 - Snapshots, thin provisioning, menos espacio"
echo "  2) raw - Mejor rendimiento, más espacio"
read_input "Seleccionar formato final (1-2)" "1" "format_choice"

case "$format_choice" in
    1) final_format="qcow2" ;;
    2) final_format="raw" ;;
    *) 
        warn "Selección inválida, usando qcow2 por defecto"
        final_format="qcow2"
        ;;
esac

# Determinar formato de la imagen original para qemu-img info
case "${image,,}" in
    *.img|*.raw)
        source_format="raw"
        ;;
    *.qcow2)
        source_format="qcow2"
        ;;
    *.vmdk)
        source_format="vmdk"
        ;;
    *)
        # Detectar formato automáticamente usando qemu-img si está disponible
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

# Importar con el formato final seleccionado
log_to_file "Importando disco: $source_format → $final_format para VM $vmid en $storage"
if ! qm importdisk "$vmid" "$image" "$storage" --format "$final_format"; then
    error "Falló la importación del disco"
fi

# Después de importar, el disco queda como "unused". Necesitamos encontrarlo y asociarlo
log "Buscando disco importado en configuración unused..."
sleep 1  # Pequeña pausa para que se actualice la configuración

# Obtener la configuración actual de la VM y buscar discos unused
unused_line=$(qm config "$vmid" | grep "^unused" | head -1)

if [ -n "$unused_line" ]; then
    # Extraer solo la clave unused (ej: unused0)
    unused_key=$(echo "$unused_line" | cut -d: -f1)
    
    log "Disco encontrado como: $unused_key"
    log "Moviendo $unused_key a scsi0..."
    
    # Intentar asociar el disco importado a scsi0 usando varios métodos. Si falla, mostrar instrucciones manuales.
    log "Intentando asociar disco con diferentes métodos..."
    
    # Extraer el ID completo del disco
    disk_full_id=$(echo "$unused_line" | cut -d: -f2- | xargs)
        
        # Método 1: ID completo
        if qm set "$vmid" --scsi0 "$disk_full_id"; then
            success "Disco asociado con ID completo"
            qm set "$vmid" --delete "$unused_key" 2>/dev/null || true
        # Método 2: Solo la referencia unused  
        elif qm set "$vmid" --scsi0 "$unused_key"; then
            success "Disco asociado usando referencia unused"
        # Método 3: Formato estándar
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
    # Si no hay unused, el disco puede haberse asociado automáticamente
    log "No se encontró disco unused, verificando si ya está asociado..."
    
    # Verificar si ya hay un disco en scsi0
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
    qm set "$vmid" --ide2 "$storage:cloudinit"
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
if [[ -f "$LOG_FILE" ]]; then
    echo -e "  - Log: $LOG_FILE"
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

success "¡VM lista para usar!"