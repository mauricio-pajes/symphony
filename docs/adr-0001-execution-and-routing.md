# ADR 0001 · Elección y ejecución por fase

- Estado: Propuesto. El incremento autorizado se encuentra en validación local.
- Fecha: 2026-11-26

## Contexto

Symphony selecciona trabajo y controla el ciclo de vida en un orquestador OTP. El ejecutor original abre una sesión de Codex App Server. El fork necesita lanzar Claude Code y Antigravity directamente, con Codex como opción predeterminada y un clasificador solo en las fases con alcance incierto.

## Decisión

Mantener el orquestador y sus contratos de claims, reintentos, reconciliación y workspace. Añadir una política optativa que asocia un estado activo a un proveedor. En los estados designados, una señal de alcance ambiguo autoriza un turno breve de clasificación en un directorio temporal. El resultado se reduce a una categoría admitida y el selector decide el proveedor para el intento.

Mantener la sesión App Server para Codex. Para Claude Code y Antigravity, lanzar un proceso local en la carpeta del ticket y leer el resultado estructurado del CLI. Cada intento tiene un proveedor fijo. Una transición a una fase distinta vuelve a pasar por el punto de despacho y conserva los archivos del ticket. Las opciones avanzadas de sesión, permisos, uso y cancelación de cada proveedor se incorporarán donde exista evidencia de necesidad.

## Alternativas

- **Hacer que todas las consultas pasen por un agente principal.** Reutiliza su integración, pero convierte el criterio de asignación en consumo extra y acopla todos los proveedores a un único agente.
- **Hacer que cada proveedor imite App Server.** Minimiza la llamada desde Elixir a costa de traducir permisos, sesiones y eventos que tienen semánticas distintas.
- **Adoptar el motor de otro fork.** Da acceso temprano a más integraciones. Reemplaza la base operativa y aumenta el trabajo de sincronizar con upstream.
- **Introducir ACP o los SDKs desde el primer día.** Es útil si se necesitan callbacks y reanudación. Los CLIs documentados permiten probar primero el reparto con menos dependencias y un alcance local explícito.

## Consecuencias y verificación

La configuración anterior conserva Codex. El primer incremento requiere CLIs autenticados, permisos acotados y acceso propio de Claude y Antigravity a Linear cuando deban actualizarlo. La clasificación es heurística y puede requerir ajuste por proyecto. El alcance de proceso local se valida con pruebas de salida estructurada, timeout y reaprovechamiento de workspace. La autenticación real y la prueba con servicios externos se verifican en el piloto.

[Diseño y roadmap](personal-symphony-design.md)
