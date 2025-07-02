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