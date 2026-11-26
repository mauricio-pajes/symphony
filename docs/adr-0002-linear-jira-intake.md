# ADR 0002 · Linear personal y requisitos en Jira

- Estado: Propuesto. El incremento autorizado se encuentra en validación local.
- Fecha: 2026-11-26

## Contexto

Mauricio gestiona una cola personal junto a tickets de Blaze que ya tienen dueño y criterios en Jira. Un enlace de Jira debe bastar para empezar sin duplicar el ticket ni cambiar su titularidad.

## Decisión

Linear conserva el identificador y el estado de ejecución. Jira se lee desde el host con la configuración de origen y, si se declara, el proyecto permitido. Symphony construye la ruta de lectura a partir de la clave y añade a la descripción que recibe el agente el resumen, criterios, comentarios accesibles y vínculos relevantes. La fase y los permisos siguen en el workflow. Las actualizaciones corporativas o la publicación de evidencia siguen las aprobaciones de Blaze.

El primer incremento reconoce enlaces de un origen configurado. Si detecta más de un ticket de ese origen, registra la ambigüedad. Los tickets sin enlace compatible conservan su descripción de Linear. El catálogo define qué repositorios puede usar cada workflow y se verifica antes de abrirlos.

## Alternativas

- **Usar Jira como tracker único.** Permite polling nativo en Blaze. Mezclaría la cola del usuario con el tablero corporativo y exigiría otro tracker para sus proyectos personales.
- **Copiar la descripción completa a Linear.** Reduce la lectura al inicio. Introduce duplicación y obliga a reconciliar decisiones cuando Jira cambia.
- **Resolver cualquier URL dentro de la tarea.** Permite más fuentes. El origen fijo y la ruta construida permiten acotar mejor las lecturas y el uso de credenciales.

## Consecuencias y verificación

Cada intento puede consultar una versión actual del ticket. El resultado del análisis registra qué requisitos usó. Los comentarios y enlaces se tratan como datos y los secretos declarados permanecen en el host. Las pruebas comprueban el origen, el proyecto, la lectura sin redirecciones y la identidad de Linear. La aprobación corporativa y las cuentas reales se verifican en un piloto con alcance acordado.

[Diseño y roadmap](personal-symphony-design.md)
