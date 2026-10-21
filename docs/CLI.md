# CLI de Napkin

## Objetivo y comportamiento acordado

Controlar la app de barra de menú desde terminal, conservando Human First. La app debe estar abierta y seguir gestionando Accessibility, actividad humana, Ollama y agentes. El CLI no es un daemon independiente.

- `napkin status`: estado de IA, modo auto/manual, espera configurada y tiempo restante.
- `napkin start`: solicita activación inmediata, sin esperar el plazo de inactividad. Rechaza el arranque si faltan permisos, el equipo está bloqueado/suspendido o hay una detención pendiente. Confirma solicitud aceptada; consultar status para comprobar disponibilidad.
- `napkin resume`: alias de start; inicia una nueva activación, no recupera generaciones ni sesiones de agentes canceladas.
- `napkin stop`: cierra inmediatamente la admisión y solicita terminar los procesos administrados. Reinicia el contador; no cambia el modo. Confirma solicitud aceptada; status permite comprobar finalización.
- `napkin mode`: consulta auto/manual.
- `napkin mode auto`: habilita activación automática tras inactividad.
- `napkin mode manual`: deshabilita activación automática; start sigue disponible.
- `napkin mode toggle`: alterna auto/manual en la app, con una única operación, y devuelve el modo resultante.
- `napkin auto on|off`: alias de mode auto|manual.
- `napkin idle get`: consulta la espera persistida.
- `napkin idle set 10m`: cambia y guarda la espera, en minutos enteros de 1 a 240, igual que Settings. Acepta minutos sin sufijo o con m. Reinicia el contador de inactividad para que reducir el tiempo no provoque una activación inesperada inmediata.
- `napkin menubar [show|hide]`: consulta o cambia la visibilidad del icono, compartida con **Show in menu bar** en Settings → System. Persiste entre reinicios; ocultarlo mantiene la app y el gateway funcionando. `napkin menubar show` permite recuperar el icono.
- `napkin agents start`: inicia una sesión del runtime configurado solo si la IA está activa.
- `napkin help`: ayuda y ejemplos; comandos inválidos y errores devuelven código de salida distinto de cero.

Cambiar mode guarda la misma preferencia automaticActivation que usa el toggle existente y actualiza inmediatamente la interfaz. No inicia ni detiene por sí mismo una sesión activa. Habilitar auto reinicia el contador; deshabilitarlo evita futuros arranques por temporizador, sin cancelar un arranque ya solicitado. Una nueva interacción humana siempre interrumpe IA, incluso tras start/resume en modo manual. No se agrega un modo que ignore teclado o mouse.

## Tecnología y estructura

App: Swift, SwiftUI/AppKit y Foundation/Network existentes, macOS 14+. CLI: script Bash con curl incluido en macOS; no necesita compilarse ni instalar dependencias. Mantener el CLI fuera del directorio de fuentes del target de la app y documentar cómo instalarlo en PATH. Reutilizar la configuración observable y los métodos de ciclo de vida existentes; no escribir UserDefaults desde un proceso externo para controlar una app abierta.

- `Napkin/`: control en el proceso de la app y transporte de comandos.
- `cli/`: ejecutable de terminal y, si hace falta, instrucciones de compilación.
- `NapkinTests/`: pruebas del control, persistencia y transporte.
- `README.md`: instalación y ejemplos de uso local/remoto.

### Distribución por ZIP

Xcode incluye `cli/napkin` como recurso ejecutable en `Napkin.app/Contents/Resources/napkin` antes de firmar la app. El ZIP de distribución contiene la app con el CLI y las rutas de control de la misma compilación. El usuario puede ejecutar el script directamente o enlazarlo desde `~/.local/bin/napkin`; no necesita clonar el repositorio ni compilar. El enlace sigue apuntando al CLI actualizado cuando se reemplaza la app en `/Applications`.

La prueba de extremo a extremo debe ejecutar el recurso del bundle y comprobar que coincide con el script fuente y conserva permisos de ejecución. Antes de empaquetar, verificar la firma del bundle y la presencia del script. El empaquetado no instala ni cambia el PATH del equipo del usuario.

### Protocolo

Reutilizar el gateway HTTP de loopback `127.0.0.1:11435`:

- `GET /control/status`: snapshot JSON con `state`, `accepting_requests`, `mode`, `automatic_activation`, `show_in_menu_bar`, `idle_minutes`, `remaining_seconds`, `starting`, `stopping`, `can_start` y `error` opcional.
- `POST /control`: requiere `Content-Type: application/json` y ausencia de Origin. Cuerpo: `{"action":"start"}`, `{"action":"stop"}`, `{"action":"mode","value":"toggle"}` `{"action":"idle","minutes":10}` o `{"action":"menubar","value":"hide"}` (también admite `show`). Acciones o valores inválidos: 400; inicio no disponible: 409. Mutaciones válidas devuelven el snapshot actualizado; start/stop devuelven 202 porque su trabajo termina asíncronamente.
- `POST /agents/start`: reutilizar la ruta existente, sin aceptar comandos arbitrarios.
- Las conexiones de control quedan excluidas de la cancelación de inferencias para que stop pueda responder. Shutdown cierra todas las conexiones.
- El CLI usa `NAPKIN_URL` si está definida, y por defecto `http://127.0.0.1:11435`. Consultas de mode, idle y menubar devuelven el snapshot completo en JSON. Los errores HTTP y de conexión producen código de salida distinto de cero.

No se incorpora autenticación propia: el acceso remoto a estas nuevas rutas permite controlar activación y preferencias. Mantener el gateway detrás de SSH o Tailscale Serve con acceso autorizado, igual que el gateway existente. Las peticiones HTTP no cuentan como actividad humana; los comandos no omiten permisos ni interrupción por teclado/mouse. No aceptar peticiones de control enviadas por páginas web mediante Origin ni Content-Type de formularios.

## Estilo

Conservar el estilo Swift existente, con métodos pequeños y MainActor para la configuración y el ciclo de vida:

```swift
settings.automaticActivation.toggle()
```

No cambiar procesos, permisos ni lógica de interrupción ajenos al control solicitado.

## Comandos de verificación

```sh
xcodebuild -project Napkin.xcodeproj -scheme Napkin \
  -destination 'platform=macOS' -derivedDataPath /tmp/Napkin-cli-build \
  CODE_SIGNING_ALLOWED=NO -only-testing:NapkinTests test
```

```sh
bash -n cli/napkin
python3 -m unittest discover -s cli/tests -v
./cli/napkin help
```

Las pruebas del CLI usan un servidor HTTP local simulado. Las pruebas Swift ejercitan el gateway real con un monitor de actividad de pruebas y preferencias aisladas. No necesitan cargar modelos.

## Plan y tareas

1. Implementar control y transporte en la app. Verificar cambios de modo, validación de tiempo y uso de los métodos de arranque/detención existentes.
2. Crear el CLI, aliases y ayuda. Verificar parsing, códigos de salida y mensajes de error.
3. Añadir pruebas de integración y documentación. Ejecutar las pruebas de Napkin y compilar el CLI; comprobar que stop responde aunque bloquee inferencia y que los controles funcionan con IA inactiva.

## Criterios de aceptación

- Auto/manual/toggle actualizan la misma preferencia persistida y visible en la app.
- Alternar dos veces devuelve al modo inicial; modo manual impide activación por temporizador.
- Start/resume no cambian el modo y siguen respetando permisos e interrupción humana.
- Idle set rechaza cero, negativos, valores mayores a 240 y entradas no numéricas sin modificar la preferencia.
- El timeout válido persiste y reinicia la cuenta; habilitar auto concede una espera completa.
- Status y los comandos de configuración funcionan mientras IA está bloqueada.
- Stop devuelve respuesta y bloquea nuevas inferencias inmediatamente.
- No se descargan modelos, ejecutan agentes ni cambian permisos durante las pruebas automatizadas.

## Límites

Siempre: preservar cambios existentes del usuario, validar argumentos y verificar compilación/pruebas.
Consultar antes: cambiar la prioridad de actividad humana o permitir ejecución continua mientras se usa la Mac.
Nunca: recuperar procesos cancelados automáticamente, terminar Ollama externo ni introducir ejecución arbitraria de shell por la API.

## Revisión

El usuario autorizó completar la especificación e implementarla. El toggle cambia la activación automática; manual conserva la interrupción humana. Los cambios se limitan al CLI, su transporte, la sincronización con los controles existentes, pruebas y documentación.
