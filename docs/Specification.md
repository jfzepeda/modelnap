# Napkin — Especificación técnica

**Plataforma:** macOS  
**Lenguaje:** Swift + SwiftUI  
**Tipo:** Aplicación nativa de barra de menú con overlay de pantalla completa  
**Objetivo:** Permitir que una Mac funcione como servidor de inferencia de IA cuando el usuario está inactivo y libere inmediatamente sus recursos cuando detecte interacción humana.

## 1. Principio fundamental: Human First

**La prioridad absoluta de Napkin es el usuario, no la IA.**

Cuando el usuario hace clic, presiona una tecla o interactúa con el trackpad, Napkin debe interrumpir inmediatamente toda actividad de IA administrada.

No importa si:
- Un modelo está generando tokens.
- Un agente está ejecutando comandos.
- Una tarea está modificando archivos.
- Una inferencia está a punto de terminar.
- Existen múltiples agentes ejecutándose en paralelo.

**No se esperan checkpoints, confirmaciones, guardado de estado ni finalización ordenada de tareas.**

Las sesiones interrumpidas se consideran terminadas definitivamente. El usuario iniciará nuevas sesiones cuando lo necesite.

### Requisitos críticos

- La interrupción debe tener prioridad sobre cualquier otra operación.
- No mostrar diálogos de confirmación.
- No esperar a que los agentes terminen.
- No intentar reanudar automáticamente las sesiones canceladas.
- Terminar los procesos administrados, incluidos sus procesos hijos, cuando sea posible.
- Descargar los modelos de memoria.
- Impedir que nuevos agentes o solicitudes vuelvan a cargar modelos durante el periodo de actividad humana.
- No terminar aplicaciones, procesos ni servicios ajenos a Napkin.

**Objetivo de rendimiento:** iniciar la interrupción en menos de 100 ms desde la detección del evento. La liberación completa de memoria puede tardar más y debe medirse por separado.

## 2. Estados de la aplicación

### AI_ACTIVE

La Mac está disponible para cargas de IA.

- El servidor de inferencia acepta solicitudes.
- Los agentes administrados pueden ejecutarse.
- Se muestra un overlay de pantalla completa.
- Se monitorean eventos de entrada del usuario.
- No existe temporizador de inactividad pendiente.

El overlay debe mostrar:

**LLM RUNNING**

*Click or press any key to take control.*

Debe ser visualmente minimalista, con fondo oscuro y un indicador discreto de actividad.

### USER_ACTIVE

El usuario tiene prioridad absoluta.

- Los agentes administrados están detenidos.
- Las inferencias activas han sido canceladas o se encuentran en proceso de terminación forzada.
- Los modelos se descargan de memoria.
- Se bloquean nuevas solicitudes de inferencia.
- El overlay desaparece inmediatamente.
- Se inicia un temporizador de inactividad de 30 minutos.

Cada nueva interacción reinicia el temporizador.

### TRANSITIONING

Estado temporal durante el cambio entre modos.

Al pasar de `AI_ACTIVE` a `USER_ACTIVE`:

1. Ocultar inmediatamente el overlay.
2. Bloquear nuevas solicitudes de IA.
3. Cancelar las inferencias activas.
4. Enviar señal de terminación a los procesos administrados.
5. Aplicar terminación forzada a los procesos supervivientes.
6. Descargar los modelos de memoria.
7. Verificar que los procesos administrados terminaron.
8. Permanecer en `USER_ACTIVE`.

Estas operaciones deben ejecutarse de forma asíncrona, sin bloquear la interfaz.

Si un proceso no puede terminarse, mostrar un error discreto y mantener bloqueada la IA. No declarar los recursos liberados hasta verificarlo.

## 3. Detección de actividad humana

Napkin debe detectar:

- Clic izquierdo, derecho y otros botones del mouse.
- Pulsaciones de teclado.
- Movimiento del mouse y trackpad.
- Scroll y gestos relevantes.
- Desbloqueo de sesión.
- Reactivación de la pantalla o de la Mac.

### Reglas

**Durante AI_ACTIVE:**
- Un solo evento de interacción humana debe iniciar inmediatamente la interrupción.
- El overlay debe desaparecer sin esperar a que los procesos terminen.
- El evento que interrumpe el overlay no debe activar accidentalmente controles de otras aplicaciones.

**Durante USER_ACTIVE:**
- Cada evento humano relevante reinicia el debounce de 30 minutos.
- El movimiento continuo del cursor debe tratarse como actividad, sin crear miles de reinicios innecesarios.
- Los eventos sintéticos generados por aplicaciones no deben considerarse actividad humana cuando sea posible distinguirlos.

La implementación puede utilizar APIs de macOS como Quartz Event Services, Core Graphics y mecanismos de consulta de inactividad del sistema, respetando los permisos requeridos.

## 4. Debounce de inactividad

**Valor predeterminado:** 30 minutos.

El temporizador mide el tiempo transcurrido desde la última interacción humana.

Ejemplo:

- 10:00 — El usuario hace clic. Se detiene la IA.
- 10:20 — El usuario escribe. El temporizador se reinicia.
- 10:45 — El usuario mueve el mouse. El temporizador se reinicia.
- 11:15 — Se cumplen 30 minutos sin actividad. La IA vuelve a estar disponible.

### Requisitos

- Debounce configurable.
- No utilizar temporizadores independientes por evento.
- Utilizar una única referencia a la última actividad.
- Considerar correctamente suspensión, reactivación y cambios del reloj del sistema.
- Evitar condiciones de carrera entre la detección de actividad y la activación de la IA.

**Importante:** cumplir el debounce no significa reanudar sesiones anteriores. Únicamente vuelve a habilitarse la infraestructura para nuevas sesiones.

## 5. Administración de procesos

Napkin debe controlar únicamente los procesos y servicios registrados explícitamente bajo su administración.

### Tipos de procesos

**Inference servers**
- Ollama.
- Servidores compatibles con MLX.
- llama.cpp.
- Otros servidores configurables mediante adaptadores.

**Agent runtimes**
- OpenCode.
- Hermes Agent.
- Otros ejecutables configurables.

### Process Manager

Crear un componente `ProcessManager` responsable de:

- Iniciar procesos administrados.
- Registrar PID y relación de procesos hijos.
- Supervisar estado y salida.
- Detener procesos.
- Ejecutar terminación forzada.
- Detectar procesos supervivientes.
- Evitar que procesos administrados se reinicien durante `USER_ACTIVE`.

Los procesos deben iniciarse en grupos o mecanismos de supervisión que permitan identificar y terminar sus descendientes.

No utilizar comandos indiscriminados como `killall`, `pkill` por nombre genérico ni terminar procesos que Napkin no pueda identificar como propios.

### Política de interrupción

1. Bloquear inmediatamente la admisión de trabajo.
2. Cancelar las solicitudes activas.
3. Terminar los agentes administrados.
4. Aplicar terminación forzada sin esperar finalización lógica de las tareas.
5. Descargar modelos.
6. Verificar el estado final.

La aplicación no garantiza consistencia de archivos modificados por agentes interrumpidos. Esta es una decisión deliberada del producto.

## 6. Gestión de modelos y memoria

La memoria debe liberarse efectivamente, no simplemente detener la generación de tokens.

### Ollama

El adaptador debe:

- Identificar modelos cargados.
- Cancelar solicitudes administradas.
- Solicitar descarga de modelos.
- Verificar mediante la API que los modelos dejaron de estar cargados.
- Impedir solicitudes nuevas mientras el usuario está activo.

### MLX / llama.cpp

Los adaptadores deben implementar mecanismos equivalentes según las capacidades reales del servidor.

Cuando el servidor mantenga los pesos residentes en memoria, Napkin podrá terminar el proceso administrado para liberar los recursos.

### Restricción

Napkin no debe asumir que enviar una señal de pausa como `SIGSTOP` libera memoria. Suspender la ejecución no equivale a descargar un modelo.

## 7. Overlay de pantalla completa

### Diseño

- Fondo negro o gris muy oscuro.
- Interfaz minimalista.
- Texto central: `LLM RUNNING`.
- Indicador visual de inferencia activa o servidor disponible.
- Mensaje: `Click or press any key to take control`.
- Sin botones de confirmación.
- Sin animaciones pesadas.

### Comportamiento

- El overlay aparece cuando la Mac entra en `AI_ACTIVE`.
- Debe cubrir las pantallas conectadas que se hayan configurado.
- Debe desaparecer inmediatamente al detectar actividad.
- No debe bloquear permanentemente el acceso al sistema.
- Debe respetar mecanismos de recuperación de macOS y permitir una salida de emergencia.

El overlay es una interfaz informativa y de recuperación de control, no un mecanismo de seguridad.

## 8. Aplicación de barra de menú

Napkin debe funcionar como aplicación residente de macOS.

### Información visible

- Estado actual: `AI ACTIVE`, `USER ACTIVE`, `TRANSITIONING` o `ERROR`.
- Tiempo restante para volver a habilitar IA.
- Modelos cargados.
- Memoria estimada utilizada por la infraestructura administrada.
- Número de procesos y agentes activos.

### Acciones

- `Stop AI Now`
- `Enable AI Now`
- `Disable Automatic Activation`
- `Settings`
- `Quit Napkin`

La acción `Stop AI Now` debe ejecutar exactamente la misma política de interrupción que una interacción humana.

La opción `Quit Napkin` debe detener primero los procesos administrados, salvo que el usuario configure explícitamente otra política.

## 9. Configuración

Persistir configuración mediante mecanismos nativos de macOS.

| Parámetro | Predeterminado |
|---|---|
| Idle timeout | 30 minutos |
| Automatic activation | Activado |
| Fullscreen overlay | Activado |
| Interrupt on keyboard | Activado |
| Interrupt on mouse click | Activado |
| Interrupt on mouse movement | Activado |
| Force termination | Activado |
| Launch at login | Configurable |
| Managed inference server | Configurable |
| Managed agent runtimes | Configurable |

La configuración debe permitir registrar comandos de inicio, rutas de ejecutables, variables de entorno y puertos locales.

Los secretos y credenciales deben almacenarse de forma segura, preferentemente mediante Keychain.

## 10. Arquitectura propuesta

Implementar la aplicación con Swift, SwiftUI y APIs nativas de macOS.

### Componentes

**AppCoordinator**
- Controla la máquina de estados.
- Coordina transiciones.
- Evita activaciones concurrentes.

**ActivityMonitor**
- Detecta actividad humana.
- Mantiene la última actividad.
- Notifica interrupciones.

**IdleScheduler**
- Implementa el debounce.
- Programa la siguiente activación.
- Gestiona suspensión y reactivación.

**ProcessManager**
- Inicia y termina procesos.
- Administra procesos descendientes.
- Supervisa errores.

**InferenceManager**
- Coordina servidores de inferencia.
- Administra modelos cargados.
- Expone adaptadores para distintos motores.

**InferenceGateway**
- Controla la admisión de nuevas solicitudes.
- Rechaza trabajo durante `USER_ACTIVE`.
- Evita la recarga accidental de modelos.

**OverlayController**
- Presenta y retira las ventanas de pantalla completa.
- Gestiona múltiples monitores.

**MenuBarController**
- Presenta el estado.
- Permite acciones manuales.

**SettingsManager**
- Persiste preferencias.
- Administra perfiles de procesos.

### Consideraciones de concurrencia

Utilizar Swift Concurrency y aislamiento mediante actores donde corresponda.

La interrupción debe tener prioridad sobre operaciones de arranque, carga de modelos y solicitudes pendientes.

Si se detecta actividad durante el arranque de un servidor, el arranque debe cancelarse y el sistema debe volver a `USER_ACTIVE`.

## 11. Comportamiento remoto

Napkin debe permitir que clientes remotos accedan al servidor de inferencia mediante una red privada, por ejemplo Tailscale.

### Durante AI_ACTIVE

- Se aceptan solicitudes autorizadas.
- Los agentes pueden utilizar modelos locales.
- Los clientes remotos pueden consultar el estado.

### Durante USER_ACTIVE

- Se rechazan nuevas solicitudes de inferencia.
- Las conexiones existentes pueden ser interrumpidas.
- No se cargan modelos automáticamente.
- Los clientes reciben una respuesta explícita indicando que la IA está temporalmente deshabilitada.

El acceso remoto no debe reiniciar el debounce de actividad humana.

La exposición de puertos debe limitarse a interfaces y clientes autorizados.

## 12. Seguridad y recuperación

Napkin debe garantizar que el usuario pueda recuperar el control de la Mac incluso si un servidor o agente falla.

Requisitos:

- No bloquear el hilo principal durante terminaciones.
- No depender del servidor de IA para detenerlo.
- Mantener una vía de salida manual.
- Registrar errores de terminación.
- Evitar reinicios automáticos inesperados.
- Recuperar un estado seguro después de fallos.
- No interceptar contraseñas ni almacenar pulsaciones de teclado.
- Solicitar únicamente los permisos de macOS necesarios.

Al iniciar la aplicación después de un cierre inesperado, no asumir que los procesos anteriores siguen bajo su control. Identificarlos de manera segura antes de intervenir.

## 13. Pruebas de aceptación

### Test 1 — Interrupción inmediata

**Given:** un modelo está generando tokens y un agente está ejecutando una tarea.

**When:** el usuario hace un clic.

**Then:** el overlay desaparece inmediatamente, se bloquean nuevas solicitudes y comienza la terminación de los procesos administrados.

### Test 2 — Interrupción sin checkpoints

**Given:** un agente está a mitad de una operación.

**When:** el usuario presiona una tecla.

**Then:** la tarea se interrumpe sin esperar su finalización ni intentar preservar la sesión.

### Test 3 — Debounce

**Given:** el sistema está en `USER_ACTIVE`.

**When:** el usuario interactúa repetidamente durante 45 minutos.

**Then:** la IA permanece deshabilitada y el temporizador se reinicia con cada interacción.

### Test 4 — Reactivación

**Given:** han transcurrido 30 minutos sin actividad.

**When:** vence el debounce.

**Then:** se habilita nuevamente la infraestructura de IA, sin reanudar sesiones canceladas.

### Test 5 — Actividad durante el arranque

**Given:** el servidor está cargando un modelo.

**When:** se detecta actividad humana.

**Then:** se cancela el arranque y se vuelve a `USER_ACTIVE`.

### Test 6 — Liberación de memoria

**Given:** hay modelos cargados en memoria.

**When:** se activa `USER_ACTIVE`.

**Then:** los modelos administrados se descargan o se terminan sus procesos y se verifica la liberación de recursos.

### Test 7 — Aislamiento

**Given:** existen aplicaciones y procesos externos a Napkin.

**When:** se interrumpe la IA.

**Then:** ninguno de esos procesos externos es terminado por Napkin.

### Test 8 — Acceso remoto

**Given:** un cliente remoto intenta realizar inferencia durante `USER_ACTIVE`.

**When:** envía una solicitud.

**Then:** la solicitud se rechaza y no provoca la carga del modelo.

## 14. Alcance del MVP

### P0 — Obligatorio

- App nativa SwiftUI.
- Barra de menú.
- Monitor de actividad humana.
- Interrupción inmediata con un solo clic o tecla.
- Terminación forzada de procesos administrados.
- Integración inicial con Ollama.
- Descarga y verificación de modelos.
- Debounce de 30 minutos.
- Bloqueo de solicitudes durante actividad humana.
- Overlay de pantalla completa.
- Manejo de errores y recuperación de control.

### P1 — Segunda fase

- Adaptadores MLX y llama.cpp.
- Integración específica con OpenCode y Hermes.
- Estadísticas de memoria y uso.
- Configuración avanzada de perfiles.
- Control de múltiples servidores.
- Mejoras de compatibilidad con monitores y Spaces.

### Fuera de alcance

- Checkpoints.
- Reanudación de sesiones interrumpidas.
- Recuperación de tareas incompletas.
- Orquestación multiagente.
- Distribución de inferencia entre varias Macs.
- Administración de procesos ajenos a Napkin.

## 15. Criterio de éxito

Napkin cumple su objetivo cuando el usuario puede dejar su Mac ejecutando modelos locales y agentes durante horas, regresar, hacer **un solo clic** y recuperar inmediatamente el control de la interfaz, mientras la aplicación termina la carga de IA y libera sus recursos.

Cuando transcurren 30 minutos sin actividad humana, la infraestructura vuelve a estar disponible para iniciar nuevas sesiones.

**Regla definitiva: Human activity always wins. No questions, no waiting for task completion, no session recovery.**