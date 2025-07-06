Principales mejoras implementadas:
🔧 Corrección del problema principal

Detección automática de formato: El script ahora detecta correctamente el formato del archivo (.img = raw, .qcow2 = qcow2, etc.)
Uso de qemu-img info: Si está disponible, detecta automáticamente el formato real del archivo
Mejor manejo de formatos: Soporte para .img, .qcow2, .raw, .vmdk

📦 Compactación y mejoras

Función read_input(): Simplifica la captura de datos con valores por defecto
Funciones de logging: Mensajes más claros y consistentes
Validaciones mejoradas: Mejor manejo de errores y casos edge
Código más limpio: Eliminé redundancias y simplifiqué la lógica

⚙️ Nuevas características

Soporte para Cloud-init: Opción para añadir automáticamente soporte Cloud-init
Mejor detección de almacenamientos: Solo muestra almacenamientos activos
Información de tamaño: Muestra el tamaño de cada imagen disponible
Resumen final: Información completa de la VM creada y comandos útiles
🎯 Valores por defecto optimizados

VM ID: 9000
Nombre: cloud-template
RAM: 2048MB (más conservador)
Sockets: 1 (más común)
Consola serial: habilitada por defecto
Cloud-init: habilitado por defecto

El script ahora es más robusto, compacto y maneja correctamente todos los formatos de imagen comunes en Proxmox.

🎯 Pasos siguientes recomendados:

Iniciar la VM para probar:
bashqm start 830

Conectar por consola:
bashqm terminal 830

Configurar Cloud-init (desde la web UI):

Usuario y contraseña
SSH keys
Configuración de red


Convertir en template (después de configurar):
bashqm template 830
Clonar para crear VMs:
bashqm clone 830 831 --name mi-nueva-vm

Principales mejoras implementadas:
1. Selección de tipo de BIOS/UEFI

SeaBIOS (Legacy): Para máxima compatibilidad con sistemas antiguos
OVMF (UEFI): Para sistemas modernos, necesario para Secure Boot
Automáticamente configura --machine q35 cuando se selecciona OVMF
Añade el disco EFI necesario para UEFI: --efidisk0

2. Redimensionado de disco con qemu-img resize

Momento ideal: Antes de importar el disco a Proxmox
Muestra el tamaño actual de la imagen
Valida que el nuevo tamaño sea mayor que el actual
Crea una copia temporal para redimensionar sin afectar la imagen original
Limpia automáticamente el archivo temporal

3. Información mejorada de imágenes

Muestra formato, tamaño en disco y tamaño virtual
Detección automática del formato de imagen

4. Función auxiliar para conversión de tamaños

Convierte formatos como "20G", "512M" a bytes para validación

Flujo del redimensionado:
1. Detectar imagen → 2. Mostrar tamaño actual → 3. Preguntar si redimensionar
→ 4. Validar nuevo tamaño → 5. Crear copia temporal → 6. Redimensionar
→ 7. Importar imagen redimensionada → 8. Limpiar temporal
Ejemplo de uso:
bash# El script ahora preguntará:
Configuración de BIOS/UEFI:
  1) SeaBIOS (Legacy BIOS) - Compatibilidad máxima  
  2) OVMF (UEFI) - Moderno, necesario para Secure Boot
Seleccionar tipo de BIOS (1-2) [1]: 2
