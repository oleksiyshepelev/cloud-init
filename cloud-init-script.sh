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

# Función mejorada para convertir tamaño a bytes
size_to_bytes() {
    local size="$1"
    # Remover espacios y convertir a minúsculas para el sufijo
    size=$(echo "$size" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    
    # Expresión regular mejorada para soportar decimales
    if [[ $size =~ ^([0-9]*\.?[0-9]+)([kmgtpe]?)(i?b?)?$ ]]; then
        local num="${BASH_REMATCH[1]}"
        local suffix="${BASH_REMATCH[2]}"
        
        # Validar que el número es válido
        if [[ ! $num =~ ^[0-9]*\.?[0-9]+$ ]]; then
            error "Número inválido: $num"
        fi
        
        # Usar bc para cálculos con decimales, con fallback a awk
        if command -v bc &> /dev/null; then
            case "$suffix" in
                ""|"b") echo "$num" | bc | cut -d. -f1 ;;
                "k") echo "$num * 1024" | bc | cut -d. -f1 ;;
                "m") echo "$num * 1024 * 1024" | bc | cut -d. -f1 ;;
                "g") echo "$num * 1024 * 1024 * 1024" | bc | cut -d. -f1 ;;
                "t") echo "$num * 1024 * 1024 * 1024 * 1024" | bc | cut -d. -f1 ;;
                "p") echo "$num * 1024 * 1024 * 1024 * 1024 * 1024" | bc | cut -d. -f1 ;;
                "e") echo "$num * 1024 * 1024 * 1024 * 1024 * 1024 * 1024" | bc | cut -d. -f1 ;;
                *) error "Sufijo desconocido: $suffix" ;;
            esac
        else
            # Fallback usando awk si bc no está disponible
            case "$suffix" in
                ""|"b") awk "BEGIN {printf \"%.0f\", $num}" ;;
                "k") awk "BEGIN {printf \"%.0f\", $num * 1024}" ;;
                "m") awk "BEGIN {printf \"%.0f\", $num * 1024 * 1024}" ;;
                "g") awk "BEGIN {printf \"%.0f\", $num * 1024 * 1024 * 1024}" ;;
                "t") awk "BEGIN {printf \"%.0f\", $num * 1024 * 1024 * 1024 * 1024}" ;;
                "p") awk "BEGIN {printf \"%.0f\", $num * 1024 * 1024 * 1024 * 1024 * 1024}" ;;
                "e") awk "BEGIN {printf \"%.0f\", $num * 1024 * 1024 * 1024 * 1024 * 1024 * 1024}" ;;
                *) error "Sufijo desconocido: $suffix" ;;
            esac
        fi
    else
        error "Formato de tamaño inválido: '$size' (use formato: 10G, 512M, 1.5G, etc.)"
    fi
}

# Función para obtener tamaño de imagen de forma más robusta
get_image_size_bytes() {
    local image="$1"
    local size_bytes=""
    
    if command -v qemu-img &> /dev/null; then
        # Intentar obtener el tamaño virtual en bytes directamente
        size_bytes=$(qemu-img info "$image" --output json 2>/dev/null | grep -o '"virtual-size": *[0-9]*' | cut -d: -f2 | tr -d ' ')
        
        # Si no funciona con JSON, intentar con formato texto
        if [ -z "$size_bytes" ] || [ "$size_bytes" = "0" ]; then
            local img_info=$(qemu-img info "$image" 2>/dev/null)
            
            # Intentar extraer bytes del formato "X.X GiB (XXXXXXXXX bytes)"
            size_bytes=$(echo "$img_info" | grep "virtual size:" | sed -n 's/.*(\([0-9,]*\) bytes).*/\1/p' | tr -d ',')
            
            # Si no hay paréntesis con bytes, intentar extraer el tamaño textual
            if [ -z "$size_bytes" ] || [ "$size_bytes" = "0" ]; then
                local size_text=$(echo "$img_info" | grep "virtual size:" | awk '{print $3}')
                if [ -n "$size_text" ]; then
                    size_bytes=$(size_to_bytes "$size_text" 2>/dev/null || echo "")
                fi
            fi
        fi
    fi
    
    echo "$size_bytes"
}

# Función para formatear bytes a formato legible
bytes_to_human() {
    local bytes="$1"
    
    if command -v numfmt &> /dev/null; then
        numfmt --to=iec-i --suffix=B "$bytes"
    elif command -v bc &> /dev/null; then
        if [ "$bytes" -ge 1099511627776 ]; then
            echo "$bytes / 1099511627776" | bc -l | awk '{printf "%.1fTiB", $1}'
        elif [ "$bytes" -ge 1073741824 ]; then
            echo "$bytes / 1073741824" | bc -l | awk '{printf "%.1fGiB", $1}'
        elif [ "$bytes" -ge 1048576 ]; then
            echo "$bytes / 1048576" | bc -l | awk '{printf "%.1fMiB", $1}'
        elif [ "$bytes" -ge 1024 ]; then
            echo "$bytes / 1024" | bc -l | awk '{printf "%.1fKiB", $1}'
        else
            echo "${bytes}B"
        fi
    else
        # Fallback simple usando awk
        awk -v bytes="$bytes" '
        BEGIN {
            if (bytes >= 1099511627776) printf "%.1fTiB", bytes/1099511627776
            else if (bytes >= 1073741824) printf "%.1fGiB", bytes/1073741824
            else if (bytes >= 1048576) printf "%.1fMiB", bytes/1048576
            else if (bytes >= 1024) printf "%.1fKiB", bytes/1024
            else printf "%dB", bytes
        }'
    fi
}

# Función para verificar dependencias
check_dependencies() {
    local missing_deps=()
    
    # Comandos críticos
    for cmd in qm pvesm; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        error "Comandos requeridos no encontrados: ${missing_deps[*]}. ¿Estás ejecutando esto en un nodo Proxmox?"
    fi
    
    # Comandos opcionales pero recomendados
    local optional_deps=()
    for cmd in qemu-img bc numfmt; do
        if ! command -v "$cmd" &> /dev/null; then
            optional_deps+=("$cmd")
        fi
    done
    
    if [ ${#optional_deps[@]} -gt 0 ]; then
        warn "Comandos opcionales no encontrados: ${optional_deps[*]}. Algunas funciones pueden estar limitadas."
    fi
}

echo -e "${BLUE}=== 🛠️  Script para crear VM desde imagen cloud ===${NC}\n"

# Verificar dependencias
check_dependencies

# Configuración con valores por defecto
read_input "ID de la VM" "9000" "vmid"
read_input "Nombre de la VM" "cloud-template" "vmname"

# Verificar si ya existe la VM
if qm status "$vmid" &>/dev/null; then
    error "Ya existe una VM con el ID $vmid"
fi

# Verificar que el ID es válido
if ! [[ "$vmid" =~ ^[0-9]+$ ]] || [ "$vmid" -lt 100 ] || [ "$vmid" -gt 999999999 ]; then
    error "ID de VM inválido: $vmid (debe ser un número entre 100 y 999999999)"
fi

# Configuración del sistema
read_input "Tipo de OS (l26/w10/other)" "l26" "ostype"

# *** NUEVA SECCIÓN: Tipo de BIOS ***
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
        # Verificar si existe el archivo OVMF
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

# Validar configuración de hardware
if ! [[ "$cores" =~ ^[0-9]+$ ]] || [ "$cores" -lt 1 ] || [ "$cores" -gt 512 ]; then
    error "Número de cores inválido: $cores (debe estar entre 1 y 512)"
fi

if ! [[ "$sockets" =~ ^[0-9]+$ ]] || [ "$sockets" -lt 1 ] || [ "$sockets" -gt 4 ]; then
    error "Número de sockets inválido: $sockets (debe estar entre 1 y 4)"
fi

if ! [[ "$memory" =~ ^[0-9]+$ ]] || [ "$memory" -lt 16 ] || [ "$memory" -gt 4194304 ]; then
    error "Memoria RAM inválida: $memory (debe estar entre 16MB y 4TB)"
fi

# Configuración de red
read_input "Bridge de red" "vmbr0" "bridge"
read_input "Modelo de NIC" "virtio" "nic_model"

# Consola serial
read_input "Habilitar consola serial (y/n)" "y" "enable_serial"

# Detectar imágenes disponibles
log "Buscando imágenes disponibles..."
mapfile -t images < <(find . -maxdepth 1 -type f \( -name "*.img" -o -name "*.qcow2" -o -name "*.raw" -o -name "*.vmdk" -o -name "*.vdi" -o -name "*.vhd" -o -name "*.vhdx" \) 2>/dev/null | sort)

if [ ${#images[@]} -eq 0 ]; then
    error "No se encontraron imágenes compatibles (.img, .qcow2, .raw, .vmdk, .vdi, .vhd, .vhdx)"
fi

echo -e "\n${BLUE}Imágenes encontradas:${NC}"
for i in "${!images[@]}"; do
    filename=$(basename "${images[$i]}")
    size=$(du -h "${images[$i]}" 2>/dev/null | cut -f1 || echo "N/A")
    
    # Mostrar información adicional de la imagen si qemu-img está disponible
    if command -v qemu-img &> /dev/null; then
        img_info=$(qemu-img info "${images[$i]}" 2>/dev/null)
        if [ -n "$img_info" ]; then
            img_format=$(echo "$img_info" | grep "file format:" | awk '{print $3}')
            virtual_size=$(echo "$img_info" | grep "virtual size:" | awk '{print $3}')
            echo "  $((i+1))) $filename ($size en disco, $virtual_size virtual, formato: $img_format)"
        else
            echo "  $((i+1))) $filename ($size, formato: desconocido)"
        fi
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

# Verificar que la imagen existe y es legible
if [ ! -f "$image" ]; then
    error "La imagen seleccionada no existe: $image"
fi

if [ ! -r "$image" ]; then
    error "No se puede leer la imagen: $image (permisos insuficientes)"
fi

# *** NUEVA SECCIÓN MEJORADA: Redimensionar disco ***
if command -v qemu-img &> /dev/null; then
    current_size_bytes=$(get_image_size_bytes "$image")
    
    if [ -n "$current_size_bytes" ] && [ "$current_size_bytes" -gt 0 ]; then
        current_size_human=$(bytes_to_human "$current_size_bytes")
        
        echo -e "\n${BLUE}Redimensionar disco:${NC}"
        echo "Tamaño actual: $current_size_human"
        read_input "¿Redimensionar disco? (y/n)" "n" "resize_disk"
        
        if [[ "$resize_disk" =~ ^[Yy]$ ]]; then
            # Bucle para permitir reintentar el tamaño
            while true; do
                read_input "Nuevo tamaño (ej: 10G, 20G, 50G, 1.5T)" "20G" "new_size"
                
                # Validar formato del nuevo tamaño
                if new_bytes=$(size_to_bytes "$new_size" 2>/dev/null); then
                    log "Comparando: actual=$current_size_bytes bytes vs nuevo=$new_bytes bytes"
                    log "Actual: $current_size_human vs Nuevo: $(bytes_to_human "$new_bytes")"
                    
                    if [ "$new_bytes" -le "$current_size_bytes" ]; then
                        echo -e "${YELLOW}El nuevo tamaño ($(bytes_to_human "$new_bytes")) debe ser mayor que el actual ($current_size_human)${NC}"
                        echo "Opciones:"
                        echo "  1) Introducir otro tamaño"
                        echo "  2) Continuar de todas formas (puede fallar)"
                        echo "  3) Cancelar redimensionado"
                        read_input "Seleccionar opción (1-3)" "1" "size_choice"
                        
                        case "$size_choice" in
                            1)
                                continue  # Volver al inicio del bucle
                                ;;
                            2)
                                warn "Continuando con tamaño potencialmente menor..."
                                resize_needed="true"
                                break
                                ;;
                            3)
                                resize_disk="n"
                                break
                                ;;
                            *)
                                warn "Opción inválida, volviendo a pedir tamaño..."
                                continue
                                ;;
                        esac
                    else
                        resize_needed="true"
                        break
                    fi
                else
                    echo -e "${RED}Formato de tamaño inválido: $new_size${NC}"
                    echo "Ejemplos válidos: 10G, 20GB, 1.5T, 512M, 2048MB"
                    continue
                fi
            done
        fi
    else
        warn "No se pudo determinar el tamaño actual de la imagen"
        read_input "¿Redimensionar disco de todas formas? (y/n)" "n" "resize_disk"
        
        if [[ "$resize_disk" =~ ^[Yy]$ ]]; then
            read_input "Nuevo tamaño (ej: 10G, 20G, 50G)" "20G" "new_size"
            if size_to_bytes "$new_size" &>/dev/null; then
                resize_needed="true"
            else
                error "Formato de tamaño inválido: $new_size"
            fi
        fi
    fi
else
    warn "qemu-img no disponible, no se puede redimensionar"
    resize_disk="n"
fi

# Obtener almacenamientos con validación mejorada
log "Obteniendo almacenamientos disponibles..."

# Intentar diferentes métodos para obtener almacenamientos
if command -v pvesm &>/dev/null; then
    mapfile -t storages < <(pvesm status 2>/dev/null | awk 'NR>1 && $2=="active" {print $1}' | sort)
    
    # Si no encuentra almacenamientos activos, intentar todos los disponibles
    if [ ${#storages[@]} -eq 0 ]; then
        warn "No se encontraron almacenamientos activos, buscando todos los disponibles..."
        mapfile -t storages < <(pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | sort)
    fi
    
    # Si aún no encuentra, intentar método alternativo
    if [ ${#storages[@]} -eq 0 ]; then
        warn "No se encontraron almacenamientos con 'pvesm status', buscando en configuración..."
        if [ -f "/etc/pve/storage.cfg" ]; then
            mapfile -t storages < <(grep -E "^[a-zA-Z]" /etc/pve/storage.cfg | grep -v "^#" | cut -d: -f1 | sort)
        fi
        
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
    # Mostrar información adicional del almacenamiento si es posible
    if command -v pvesm &>/dev/null; then
        storage_info=$(pvesm status "${storages[$i]}" 2>/dev/null | tail -1)
        if [ -n "$storage_info" ]; then
            storage_type=$(echo "$storage_info" | awk '{print $3}')
            storage_size=$(echo "$storage_info" | awk '{print $4}')
            storage_used=$(echo "$storage_info" | awk '{print $5}')
            storage_avail=$(echo "$storage_info" | awk '{print $6}')
            echo "  $((i+1))) ${storages[$i]} ($storage_type, disponible: $storage_avail)"
        else
            echo "  $((i+1))) ${storages[$i]}"
        fi
    else
        echo "  $((i+1))) ${storages[$i]}"
    fi
done

read_input "Seleccionar almacenamiento (número)" "1" "storage_choice"
storage_index=$((storage_choice - 1))

if [[ $storage_index -lt 0 || $storage_index -ge ${#storages[@]} ]]; then
    error "Selección de almacenamiento inválida"
fi

storage="${storages[$storage_index]}"

# Verificar que el almacenamiento está disponible
if ! pvesm status "$storage" &>/dev/null; then
    error "El almacenamiento '$storage' no está disponible"
fi

# Controlador SCSI
read_input "Controlador SCSI (virtio-scsi-single/virtio-scsi-pci/lsi)" "virtio-scsi-single" "scsihw"

# Crear VM
log "Creando VM con ID $vmid..."

create_cmd="qm create $vmid"
create_cmd+=" --name \"$vmname\""
create_cmd+=" --ostype \"$ostype\""
create_cmd+=" --cpu \"cputype=$cputype\""
create_cmd+=" --cores $cores"
create_cmd+=" --sockets $sockets"
create_cmd+=" --memory $memory"
create_cmd+=" --net0 \"$nic_model,bridge=$bridge\""
create_cmd+=" --scsihw \"$scsihw\""
create_cmd+=" --machine \"$machine_type\""

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

log "Ejecutando: $create_cmd"
eval "$create_cmd" || error "Falló la creación de la VM"

# *** REDIMENSIONAR IMAGEN ANTES DE IMPORTAR ***
if [[ "$resize_disk" =~ ^[Yy]$ && "$resize_needed" == "true" ]]; then
    log "Redimensionando imagen a $new_size..."
    
    # Crear copia temporal para redimensionar
    temp_image="/tmp/$(basename "$image").resized.$$"
    
    # Crear directorio temporal si no existe
    mkdir -p "$(dirname "$temp_image")"
    
    log "Creando copia temporal: $temp_image"
    if ! cp "$image" "$temp_image"; then
        error "No se pudo crear copia temporal en $temp_image"
    fi
    
    log "Redimensionando imagen temporal..."
    if qemu-img resize "$temp_image" "$new_size" 2>/dev/null; then
        success "Imagen redimensionada exitosamente a $new_size"
        image="$temp_image"
        cleanup_temp="true"
    else
        warn "Falló el redimensionado directo, intentando con qemu-img convert..."
        temp_image2="/tmp/$(basename "$image").converted.$$"
        
        if qemu-img convert -O qcow2 "$temp_image" "$temp_image2" && qemu-img resize "$temp_image2" "$new_size"; then
            success "Imagen convertida y redimensionada exitosamente"
            rm -f "$temp_image"
            image="$temp_image2"
            temp_image="$temp_image2"
            cleanup_temp="true"
        else
            error "Falló el redimensionado de la imagen"
        fi
    fi
fi

# Importar disco - CORRECCIÓN del problema original
log "Importando disco desde $(basename "$image")..."

# *** NUEVA SECCIÓN: Selección de formato de salida ***
echo -e "\n${BLUE}Formato del disco en Proxmox:${NC}"
echo "  1) raw - Mejor rendimiento, más espacio"
echo "  2) qcow2 - Snapshots, thin provisioning, menos espacio"
read_input "Seleccionar formato final (1-2)" "1" "format_choice"

case "$format_choice" in
    1) final_format="raw" ;;
    2) final_format="qcow2" ;;
    *) 
        warn "Selección inválida, usando raw por defecto"
        final_format="raw"
        ;;
esac

# Determinar formato de la imagen original
if command -v qemu-img &> /dev/null; then
    detected_format=$(qemu-img info "$image" 2>/dev/null | grep "file format:" | awk '{print $3}')
    source_format="${detected_format:-raw}"
    log "Formato origen detectado: $source_format"
else
    # Detectar por extensión como fallback
    case "${image,,}" in
        *.img|*.raw) source_format="raw" ;;
        *.qcow2) source_format="qcow2" ;;
        *.vmdk) source_format="vmdk" ;;
        *.vdi) source_format="vdi" ;;
        *.vhd) source_format="vpc" ;;
        *.vhdx) source_format="vhdx" ;;
        *) source_format="raw" ;;
    esac
    warn "qemu-img no disponible, detectando formato por extensión: $source_format"
fi

# Importar con el formato final seleccionado
log "Importando disco: $source_format → $final_format"
if ! qm importdisk "$vmid" "$image" "$storage" --format "$final_format"; then
    error "Falló la importación del disco"
fi

# Limpiar archivo temporal si se creó
if [[ "${cleanup_temp:-}" == "true" ]]; then
    rm -f "$temp_image"
    log "Archivo temporal eliminado"
fi

# Después de importar, el disco queda como "unused". Necesitamos encontrarlo y asociarlo
log "Buscando disco importado en configuración unused..."
sleep 2  # Pausa para que se actualice la configuración

# Función para asociar disco unused
associate_unused_disk() {
    local vmid="$1"
    local max_retries=3
    local retry=0
    
    while [ $retry -lt $max_retries ]; do
        # Obtener la configuración actual de la VM y buscar discos unused
        local unused_line=$(qm config "$vmid" | grep "^unused" | head -1)
        
        if [ -n "$unused_line" ]; then
            # Extraer solo la clave unused (ej: unused0)
            local unused_key=$(echo "$unused_line" | cut -d: -f1)
            local disk_full_id=$(echo "$unused_line" | cut -d: -f2- | xargs)
            
            log "Disco encontrado como: $unused_key ($disk_full_id)"
            log "Asociando disco a scsi0..."
            
            # Intentar diferentes métodos de asociación
            if qm set "$vmid" --scsi0 "$disk_full_id" 2>/dev/null; then
                success "Disco asociado exitosamente"
                # Limpiar la entrada unused
                qm set "$vmid" --delete "$unused_key" 2>/dev/null || true
                return 0
            elif qm set "$vmid" --scsi0 "$unused_key" 2>/dev/null; then
                success "Disco asociado usando referencia unused"
                return 0
            else
                warn "Intento $((retry+1)) fallido"
                ((retry++))
                sleep 1
            fi
        else
            # Si no hay unused, verificar si ya está asociado
            if qm config "$vmid" | grep -q "^scsi0:"; then
                success "El disco ya está asociado correctamente"
                return 0
            else
                warn "No se encontró disco unused, intento $((retry+1))"
                ((retry++))
                sleep 1
            fi
        fi
    done
    
    error "No se pudo asociar el disco después de $max_retries intentos.
    
Puedes asociar el disco manualmente:
  1) Obtener configuración: qm config $vmid
  2) Buscar línea 'unused0' (o similar)
  3) Asociar: qm set $vmid --scsi0 <valor_unused>
  
O desde la interfaz web de Proxmox:
  Hardware → Unused Disk → Edit → Seleccionar SCSI0"
}

# Ejecutar asociación del disco
associate_unused_disk "$vmid"

# Configurar arranque
read_input "Configurar como disco de arranque (y/n)" "y" "set_boot"
if [[ "$set_boot" =~ ^[Yy]$ ]]; then
    log "Configurando orden de arranque..."
    if qm set "$vmid" --boot order=scsi0; then
        success "Orden de arranque configurado"
    else
        warn "No se pudo configurar el orden de arranque automáticamente"
    fi
fi

# Cloud-init (opcional)
read_input "Añadir soporte para Cloud-init (y/n)" "y" "add_cloudinit"
if [[ "$add_cloudinit" =~ ^[Yy]$ ]]; then
    log "Añadiendo Cloud-init..."
    if qm set "$vmid" --ide2 "$storage:cloudinit"; then
        success "Cloud-init añadido"
        # Configurar tipo de cloud-init
        if qm set "$vmid" --citype nocloud; then
            log "Tipo de cloud-init configurado: nocloud"
        else
            warn "No se pudo configurar el tipo de cloud-init"
        fi
    else
        warn "No se pudo añadir Cloud-init"
    fi
fi

# Configuraciones adicionales opcionales
echo -e "\n${BLUE}Configuraciones adicionales:${NC}"

# Configurar agent
read_input "Habilitar QEMU Guest Agent (y/n)" "y" "enable_agent"
if [[ "$enable_agent" =~ ^[Yy]$ ]]; then
    log "Habilitando QEMU Guest Agent..."
    qm set "$vmid" --agent enabled=1 || warn "No se pudo habilitar el guest agent"
fi

# Configurar protección
read_input "Habilitar protección contra eliminación (y/n)" "n" "enable_protection"
if [[ "$enable_protection" =~ ^[Yy]$ ]]; then
    log "Habilitando protección..."
    qm set "$vmid" --protection 1 || warn "No se pudo habilitar la protección"
fi

# Configurar inicio automático
read_input "Habilitar inicio automático (y/n)" "n" "enable_autostart"
if [[ "$enable_autostart" =~ ^[Yy]$ ]]; then
    log "Habilitando inicio automático..."
    qm set "$vmid" --onboot 1 || warn "No se pudo habilitar el inicio automático"
fi

# Función para mostrar configuración final
show_final_config() {
    local vmid="$1"
    
    echo -e "\n${BLUE}Configuración final de la VM:${NC}"
    if qm config "$vmid" 2>/dev/null; then
        echo ""
    else
        warn "No se pudo obtener la configuración final"
    fi
}

# Función para validar VM creada
validate_vm() {
    local vmid="$1"
    local errors=0
    
    log "Validando VM creada..."
    
    # Verificar que la VM existe
    if ! qm status "$vmid" &>/dev/null; then
        error "La VM $vmid no existe después de la creación"
        ((errors++))
    fi
    
    # Verificar que tiene disco principal
    if ! qm config "$vmid" | grep -q "^scsi0:"; then
        warn "La VM no tiene disco principal configurado (scsi0)"
        ((errors++))
    fi
    
    # Verificar configuración de red
    if ! qm config "$vmid" | grep -q "^net0:"; then
        warn "La VM no tiene interfaz de red configurada"
        ((errors++))
    fi
    
    if [ $errors -eq 0 ]; then
        success "VM validada correctamente"
        return 0
    else
        warn "VM creada con $errors advertencias"
        return 1
    fi
}

# Validar VM
validate_vm "$vmid"

# Mostrar configuración final
show_final_config "$vmid"

# Resumen final mejorado
echo -e "\n${GREEN}✅ VM creada exitosamente!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Detalles de la VM:${NC}"
echo "  • ID: $vmid"
echo "  • Nombre: $vmname"
echo "  • Imagen origen: $(basename "$image")"
echo "  • Almacenamiento: $storage"
echo "  • CPU: $cores cores, $sockets sockets ($cputype)"
echo "  • RAM: ${memory}MB"
echo "  • BIOS: $bios_type"
echo "  • Máquina: $machine_type"
echo "  • Formato disco: $final_format"
echo "  • Red: $nic_model en $bridge"
echo "  • Controlador SCSI: $scsihw"

if [[ "$resize_disk" =~ ^[Yy]$ && "$resize_needed" == "true" ]]; then
    echo "  • Disco redimensionado a: $new_size"
fi

if [[ "$enable_serial" =~ ^[Yy]$ ]]; then
    echo "  • Consola serial: habilitada"
fi

if [[ "$enable_agent" =~ ^[Yy]$ ]]; then
    echo "  • QEMU Guest Agent: habilitado"
fi

if [[ "$enable_protection" =~ ^[Yy]$ ]]; then
    echo "  • Protección: habilitada"
fi

if [[ "$enable_autostart" =~ ^[Yy]$ ]]; then
    echo "  • Inicio automático: habilitado"
fi

echo -e "\n${BLUE}Discos creados:${NC}"
echo "  • scsi0: Disco principal del sistema ($final_format)"
if [ "$bios_type" = "ovmf" ]; then
    echo "  • efidisk0: Disco EFI para arranque UEFI (~1MB)"
fi
if [[ "$add_cloudinit" =~ ^[Yy]$ ]]; then
    echo "  • ide2: Disco Cloud-init (~4MB)"
fi

echo -e "\n${BLUE}Comandos útiles:${NC}"
echo "  • Ver configuración: qm config $vmid"
echo "  • Iniciar VM: qm start $vmid"
echo "  • Detener VM: qm stop $vmid"
echo "  • Reiniciar VM: qm restart $vmid"
echo "  • Estado actual: qm status $vmid"
echo "  • Convertir en template: qm template $vmid"
echo "  • Consola VNC: qm monitor $vmid"
echo "  • Clonar VM: qm clone $vmid <nuevo_id>"
echo "  • Eliminar VM: qm destroy $vmid"

if [[ "$enable_serial" =~ ^[Yy]$ ]]; then
    echo "  • Consola serial: qm terminal $vmid"
fi

if [[ "$add_cloudinit" =~ ^[Yy]$ ]]; then
    echo -e "\n${BLUE}Cloud-init configurado:${NC}"
    echo "  • Configurar usuario: qm set $vmid --ciuser <usuario>"
    echo "  • Configurar contraseña: qm set $vmid --cipassword <contraseña>"
    echo "  • Configurar SSH keys: qm set $vmid --sshkeys <archivo_keys>"
    echo "  • Configurar IP: qm set $vmid --ipconfig0 ip=<ip>/<mascara>,gw=<gateway>"
    echo "  • Configurar DNS: qm set $vmid --nameserver <dns_server>"
fi

echo -e "\n${BLUE}Próximos pasos recomendados:${NC}"
echo "  1. Configurar cloud-init si está habilitado"
echo "  2. Ajustar configuraciones específicas según el SO"
echo "  3. Probar inicio de la VM: qm start $vmid"
echo "  4. Verificar conectividad de red"
echo "  5. Instalar QEMU Guest Agent en la VM (si no está incluido)"

if [ "$bios_type" = "ovmf" ]; then
    echo "  6. Verificar arranque UEFI correcto"
fi

echo -e "\n${BLUE}Troubleshooting:${NC}"
echo "  • Si la VM no inicia, verificar: qm config $vmid"
echo "  • Para acceso por consola: usar VNC o consola serial"
echo "  • Logs del sistema: journalctl -u pve-manager"
echo "  • Logs de la VM: tail -f /var/log/pve/qemu-server/<vmid>.log"

echo -e "\n${GREEN}🎉 ¡VM lista para usar!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

# Función de limpieza final
cleanup_script() {
    # Limpiar archivos temporales si existen
    if [[ "${cleanup_temp:-}" == "true" && -n "${temp_image:-}" ]]; then
        rm -f "$temp_image"
        log "Limpieza final completada"
    fi
}

# Ejecutar limpieza al finalizar
cleanup_script

# Preguntar si quiere iniciar la VM
echo -e "\n${BLUE}¿Deseas iniciar la VM ahora?${NC}"
read_input "Iniciar VM $vmid (y/n)" "n" "start_vm"

if [[ "$start_vm" =~ ^[Yy]$ ]]; then
    log "Iniciando VM $vmid..."
    if qm start "$vmid"; then
        success "VM $vmid iniciada exitosamente"
        
        # Esperar un poco y mostrar estado
        sleep 3
        vm_status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
        echo "Estado actual: $vm_status"
        
        if [ "$vm_status" = "running" ]; then
            echo -e "\n${GREEN}✅ VM $vmid está ejecutándose correctamente${NC}"
            
            # Mostrar información de conexión
            echo -e "\n${BLUE}Información de conexión:${NC}"
            echo "  • Consola web: https://<proxmox-ip>:8006"
            echo "  • Consola VNC: qm monitor $vmid"
            
            if [[ "$enable_serial" =~ ^[Yy]$ ]]; then
                echo "  • Consola serial: qm terminal $vmid"
            fi
            
            if [[ "$add_cloudinit" =~ ^[Yy]$ ]]; then
                echo "  • La VM puede tardar unos minutos en completar cloud-init"
            fi
        else
            warn "La VM no está ejecutándose. Estado: $vm_status"
            echo "Verificar logs con: tail -f /var/log/pve/qemu-server/$vmid.log"
        fi
    else
        error "No se pudo iniciar la VM $vmid"
    fi
else
    echo -e "\n${BLUE}Para iniciar la VM más tarde, usa:${NC}"
    echo "  qm start $vmid"
fi

echo -e "\n${BLUE}¡Gracias por usar el script de creación de VMs!${NC}"
exit 0