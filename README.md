# Napkin

App nativa de barra de menú para macOS 14+, SwiftUI + AppKit. Implementa el MVP Human First de [la especificación](docs/Specification.md): el usuario recupera la interfaz inmediatamente y la infraestructura administrada se termina sin checkpoints ni reanudación.

## Ejecutar

1. Abrir `Napkin.xcodeproj` y seleccionar el scheme compartido **Napkin**, destino **My Mac**. El producto es `Napkin.app`.
2. Ejecutar con ⌘R. El icono de luna aparece en la barra de menú, sin ventana principal ni icono en el Dock (`LSUIElement = YES`).
3. En el menú, pulsar **Open permission settings…** y habilitar **Accessibility** para **Napkin** en Ajustes del Sistema → Privacidad y seguridad. El filtro activo se comprueba creándolo; no se bloquea por el preflight de Input Monitoring, que corresponde a escucha pasiva. Si macOS solicita reiniciar la app, hacerlo. La app no habilita IA sin un event tap operativo.
4. En **Settings**, indicar la ruta del ejecutable de Ollama. El valor inicial es `/opt/homebrew/bin/ollama`; no se instala Ollama ni se descargan modelos automáticamente.
5. Pulsar **Start AI Now** y dejar de interactuar. El overlay cubre todas las pantallas. Un clic, tecla, movimiento o scroll lo retira y bloquea la IA. Cada interacción reinicia el plazo predeterminado de 30 minutos.

App Sandbox está desactivado: lanzar ejecutables arbitrarios administrados y usar un event tap activo requiere distribución fuera de la sandbox de App Store. Se conserva Hardened Runtime. Para distribución se requiere firma/notarización con una identidad propia; la compilación de validación no está notarizada.

## Descargar el release

El binario universal (arm64 + x86_64) está en `dist/Napkin-2.0-macOS.zip`. Para bajar **solo ese zip**, sin el resto del repositorio ni su historial:

```sh
git clone --depth 1 --filter=blob:none --sparse https://github.com/jfzepeda/modelnap.git napkin-release
cd napkin-release
git sparse-checkout set --no-cone '/dist/Napkin-2.0-macOS.zip'
unzip dist/Napkin-2.0-macOS.zip -d /Applications
```

Requiere git 2.25 o superior. Sin git, equivale a:

```sh
curl -LO https://github.com/jfzepeda/modelnap/raw/main/dist/Napkin-2.0-macOS.zip
```

Como la firma es Apple Development y no está notarizada, la primera vez hay que abrir la app con clic derecho → Abrir.

## Guía de instalación: Mac Studio + MacBook

Escenario: el **Mac Studio** es el servidor (Ollama, el modelo y Napkin) y la **MacBook** es el cliente, conectados por Tailscale. Requiere macOS 14+; Qwen3-Coder 30B pesa unos 19 GB, por lo que conviene 32 GB de RAM o más en el Studio.

Napkin arranca su propio Ollama privado al pulsar Start AI Now: no dejar `ollama serve` corriendo en el Studio. El gateway no tiene autenticación, así que se expone solo por Tailscale, nunca a Internet.

### 1. Mac Studio (servidor)

1. Instalar Ollama:

   ```sh
   brew install ollama
   ```

2. Descargar el modelo. `ollama pull` necesita un servidor activo solo mientras descarga:

   ```sh
   brew services start ollama
   ollama pull qwen3-coder:30b
   ollama list
   brew services stop ollama
   ```

   Los modelos quedan en `~/.ollama/models`. Se comprueba que Napkin los ve en el paso 5.

3. Instalar [Tailscale](https://tailscale.com/download/mac) e iniciar sesión. Anotar el nombre MagicDNS del equipo con `tailscale status` (por ejemplo `mac-studio.tu-tailnet.ts.net`).
4. Instalar Napkin (sección anterior), conceder **Accessibility** y, en Settings, dejar la ruta de Ollama en `/opt/homebrew/bin/ollama`.
5. Pulsar **Start AI Now**, dejar de interactuar y comprobar:

   ```sh
   curl http://127.0.0.1:11435/status
   curl http://127.0.0.1:11435/api/tags
   ```

   `/api/tags` debe listar `qwen3-coder:30b`. Si se usa el equipo, las peticiones reciben 503: es lo esperado.

6. Exponer el gateway solo a la tailnet:

   ```sh
   tailscale serve --bg 11435
   ```

   No usar `tailscale funnel`: publicaría el gateway en Internet. Para revisar o quitar: `tailscale serve status` y `tailscale serve reset`. Si la app de Tailscale no instaló el comando, usar `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.

7. Evitar que el Studio se suspenda si debe estar disponible: un Mac dormido no responde y Napkin detiene la IA al suspender o bloquear.

### 2. MacBook (cliente)

1. Instalar Tailscale con la misma cuenta y comprobar que ve al Studio (`tailscale status`).
2. Instalar el cliente de Ollama (no hace falta el modelo aquí):

   ```sh
   brew install ollama
   ```

3. Usar el modelo a través del Studio:

   ```sh
   curl https://mac-studio.tu-tailnet.ts.net/status
   export OLLAMA_HOST=https://mac-studio.tu-tailnet.ts.net
   ollama run qwen3-coder:30b
   ```

   Para herramientas compatibles con OpenAI, la base URL es `https://mac-studio.tu-tailnet.ts.net/v1`. No ejecutar `ollama serve` con ese `OLLAMA_HOST`.

Alternativa sin Tailscale Serve, con túnel SSH (requiere Sesión remota activa en el Studio):

```sh
ssh -N -L 11435:127.0.0.1:11435 usuario@mac-studio.tu-tailnet.ts.net
export OLLAMA_HOST=http://127.0.0.1:11435
```

### 3. Uso de Napkin

- **USER ACTIVE**: se está usando el Studio; la IA está apagada y las peticiones reciben 503.
- **AI ACTIVE**: pasó el tiempo de inactividad (30 min por defecto) o se pulsó Start AI Now.
- Al volver al Studio (clic, tecla, movimiento o scroll) se retira el overlay, se corta el streaming y se termina Ollama; la IA no se reanuda sola.

| Síntoma                         | Causa probable                                                                           |
| ------------------------------- | ---------------------------------------------------------------------------------------- |
| 503 desde la MacBook            | Alguien usa el Studio, o no se pulsó Start AI Now. Revisar `/status`.                    |
| `Address already in use`        | Otro proceso ocupa el 11435. Cerrarlo y pulsar Retry connection.                         |
| Ollama responde con USER ACTIVE | Hay un Ollama externo en el 11434. Detenerlo con `brew services stop ollama`.            |
| La IA no arranca                | Falta el permiso de Accessibility o la ruta de Ollama es incorrecta.                     |
| No resuelve el nombre           | Revisar que ambos equipos estén Connected y usar el nombre exacto de `tailscale status`. |

Si la tailnet se comparte con otras personas, limitar el acceso al Studio con ACLs en el panel de Tailscale.

## CLI de control

La [especificación del CLI](docs/CLI.md) define los comandos y el protocolo. El ZIP 2.0 incluye el CLI dentro de `Napkin.app`; no hace falta descargar el repositorio ni compilar. El CLI es un script Bash que usa el `curl` de macOS, sin dependencias adicionales.

Después de copiar Napkin a `/Applications` y abrirla, se puede ejecutar directamente:

```sh
/Applications/Napkin.app/Contents/Resources/napkin help
/Applications/Napkin.app/Contents/Resources/napkin status
```

Para instalar el comando en una carpeta del usuario:

```sh
mkdir -p "$HOME/.local/bin"
ln -sfn /Applications/Napkin.app/Contents/Resources/napkin "$HOME/.local/bin/napkin"
export PATH="$HOME/.local/bin:$PATH"
```

Agregar ese `export PATH` a `~/.zshrc` para conservarlo en nuevas terminales. El enlace usa el CLI incluido en la app y se actualiza al reemplazarla. Si se instala la app en otra carpeta, ajustar la ruta del enlace.

Para desarrollo desde el repositorio, el mismo script está en `cli/napkin` y puede ejecutarse con `./cli/napkin help`.

```sh
napkin status          # Consultar estado y configuración
napkin mode auto       # Activar IA después de inactividad
napkin mode manual     # Activar IA solo cuando lo solicites
napkin mode toggle     # Alternar automático/manual
napkin idle set 10m    # Guardar espera de 10 minutos (1–240)
napkin idle get        # Consultar espera
napkin start           # Activar IA inmediatamente
napkin resume          # Igual que start; no recupera trabajo cancelado
napkin stop            # Detener IA
napkin agents start    # Iniciar el agente configurado
napkin help            # Ver ayuda
```

La configuración usa las mismas preferencias que los controles de la app. Pasar de manual a automático, o cambiar el tiempo de espera, reinicia el contador. Cambiar el modo no detiene una sesión activa ni cancela un arranque ya solicitado. Stop reinicia la espera y conserva el modo: con automático habilitado, la IA podrá activarse al cumplirse ese nuevo plazo.

**Start y resume siguen sujetos a Human First:** una nueva tecla, movimiento o clic detiene la IA incluso en modo manual. La liberación de Enter que ejecutó el comando no cuenta como nueva interacción. Para consumir inferencia continuamente, usar un cliente remoto mientras la Mac servidora está inactiva.

Los comandos imprimen JSON. Las consultas `mode` e `idle get` devuelven el estado completo, incluido `mode`, `idle_minutes` y `remaining_seconds`. Start/stop confirman una solicitud aceptada (HTTP 202); consultar `napkin status` para comprobar la transición. Los argumentos inválidos devuelven código de salida 2; los errores HTTP o de conexión, 1.

El control usa `GET /control/status` y `POST /control` en el gateway existente. El POST requiere JSON y rechaza cabeceras Origin de páginas web. Estas rutas funcionan también cuando la inferencia está bloqueada y no incorporan autenticación propia: quien tenga acceso al transporte privado puede solicitar activación y cambiar preferencias. Restringir ese acceso con SSH o las ACLs de Tailscale. No publicar el gateway en Internet.

Para el túnel SSH descrito en Acceso remoto, el CLI usa su URL predeterminada. Para Tailscale Serve:

```sh
NAPKIN_URL=https://mac-studio.tu-tailnet.ts.net napkin status
```

Comprobar el script y sus pruebas sin iniciar modelos ni agentes:

```sh
bash -n cli/napkin
python3 -m unittest discover -s cli/tests -v
```

## Clientes y agentes

Usar siempre **`http://127.0.0.1:11435`**, nunca el puerto privado del servidor. El gateway transmite respuestas JSON, NDJSON y SSE con backpressure; cancela conexiones admitidas al interrumpir IA.

```sh
curl http://127.0.0.1:11435/status
curl http://127.0.0.1:11435/api/tags
curl http://127.0.0.1:11435/api/chat \
  -H 'Content-Type: application/json' \
  -d '{"model":"MODELO_INSTALADO","messages":[{"role":"user","content":"Hola"}]}'
```

Durante actividad humana, las solicitudes reciben **HTTP 503** y no alcanzan Ollama. `/status` sigue disponible. Se exponen `/api/tags`, `/api/ps`, `/api/version`, `/api/generate`, `/api/chat`, `/api/embed`, `/api/embeddings` y endpoints OpenAI de modelos, chat, completions y embeddings. No se exponen descarga, borrado ni publicación de modelos. Preparar modelos con las herramientas de Ollama fuera de Napkin.

En Settings se puede registrar **un runtime de agente**, con ruta absoluta y un argumento por línea. No hay expansión de shell. Para iniciar una sesión nueva, desde un cliente externo mientras AI está activo:

```sh
curl -X POST http://127.0.0.1:11435/agents/start
```

El endpoint solo ejecuta el runtime configurado localmente; no acepta comandos arbitrarios en el cuerpo. Cada sesión tiene un grupo de procesos propio. Se admiten hasta ocho agentes simultáneos. Se proporcionan `OLLAMA_HOST` y `OPENAI_BASE_URL` apuntando al gateway. El runtime debe respetar esas variables o configurarse para usar ese endpoint. Los agentes nunca se inician al vencer el debounce. No guardar secretos en rutas ni argumentos; este MVP no incluye un editor de credenciales.

## Si Ollama sigue respondiendo mientras Napkin muestra USER ACTIVE

La CLI de Ollama normalmente utiliza `127.0.0.1:11434`. Ese servidor es externo y no está administrado por Napkin. Los contadores del menú corresponden únicamente a la instancia administrada; ahora el menú consulta `/api/ps` del puerto externo cada cinco segundos y muestra una advertencia separada si responde. Esa consulta solo lee metadatos, no carga ni descarga modelos.

Para una sesión nueva de CLI, seleccionar el gateway explícitamente:

```sh
export OLLAMA_HOST=http://127.0.0.1:11435
ollama run NOMBRE_DEL_MODELO
```

No ejecutar `ollama serve` con ese host: el puerto 11435 pertenece al gateway. Napkin arranca su servidor privado al pulsar Start AI Now. Si aparece Address already in use, hay otro proceso en ese puerto; hay que cerrarlo y pulsar Retry connection.

Mientras USER ACTIVE, recibir HTTP 503 es correcto. Escribir en esta misma Mac interrumpe deliberadamente la inferencia; para probar una generación sostenida, usar un cliente remoto con el túnel descrito abajo. Cambiar la variable no migra sesiones anteriores ni descarga modelos del servidor externo. Si se quiere que Napkin sea la única infraestructura, cerrar el servidor externo mediante su propio mecanismo de control antes de usar Napkin.

## Acceso remoto

El gateway escucha **solo en loopback**. Para acceder desde otra Mac, usar un túnel SSH sobre una red privada o un proxy privado autenticado (por ejemplo, Tailscale Serve) dirigido a `127.0.0.1:11435`. Configurar la autorización/ACL en esa capa. No publicar con un túnel público ni reenviar el puerto directamente a Internet: el gateway confía en el transporte local y no incorpora autenticación propia. Las solicitudes de red no reinician el debounce.

Ejemplo con una Mac ya accesible por SSH en la red privada:

```sh
ssh -N -L 11435:127.0.0.1:11435 usuario@mac-privada
```

## Implementación

- `AppCoordinator`: estados, prioridad de interrupción y generación de transición para invalidar arranques anteriores.
- `ActivityMonitor`: event tap activo en el run loop principal; consume el evento que interrumpe y su liberación para evitar clics/teclas accidentales en otra aplicación. Ignora eventos identificables como publicados por procesos. No captura texto.
- `IdleScheduler`: una marca monotónica de última actividad; un único ticker. Despertar, desbloquear y cambiar pantallas reinicia la actividad. Suspensión/bloqueo detiene IA.
- `ProcessManager`: `posix_spawn` con grupos propios, SIGTERM + SIGKILL sin esperar checkpoints, comprobación de miembros vivos y recolección del hijo. Retiene el PID del hijo sin recolectarlo hasta limpiar el grupo para impedir que una reutilización de PID alcance procesos ajenos.
- `InferenceManager`: API Ollama `/api/ps`, descarga explícita con `keep_alive: 0` y verificación. En la ruta urgente se termina el servidor privado y sus runners; no se espera a que una API de descarga responda. La finalización del grupo verifica que sus procesos ya no mantienen los modelos residentes.
- `InferenceGateway`: admisión cerrada por defecto, cancelación de streaming, rutas permitidas y límites de 16 conexiones, 8 MiB por petición y 15 segundos para recibirla. HTTP/1.1 con Content-Length; heartbeat `HEAD /` compatible con la CLI de Ollama y consulta `/api/show`; no acepta cuerpos chunked, pipelining ni `Expect: 100-continue`.
- `OverlayController`: ventanas AppKit en todas las pantallas, sin secuestrar mecanismos de recuperación de macOS.
- `SettingsManager`: UserDefaults y ServiceManagement para inicio de sesión.

La API de Ollama usada está documentada en [Ollama API](https://github.com/ollama/ollama/blob/main/docs/api.md). El tamaño mostrado es la suma de `size` reportada por `/api/ps`, no una medición de toda la memoria física del sistema.

## Verificación

```sh
xcodebuild -project 'Napkin.xcodeproj' -scheme Napkin \
  -destination 'platform=macOS' -derivedDataPath /tmp/Napkin-build \
  CODE_SIGNING_ALLOWED=NO test
```

Swift Testing verifica debounce, framing HTTP, rutas restringidas, bloqueo 503, permisos ausentes, cancelación previa al arranque, limpieza tras salida y terminación de grupos manteniendo vivo un proceso externo. Si existe `/opt/homebrew/bin/ollama`, también prueba una instancia privada real: arranque, `/api/ps`, gateway activo, bloqueo y terminación. No carga ni descarga modelos en esa prueba.

### Validación interactiva pendiente

Con permisos concedidos y un modelo local disponible:

1. Iniciar una generación desde otro equipo; comprobar que un clic retira el overlay, corta el stream y produce 503 en nuevas peticiones.
2. Repetir con tecla, scroll, movimiento, suspensión/despertar y varias pantallas; comprobar que el evento inicial no activa controles detrás del overlay.
3. Interactuar mientras Ollama arranca y verificar que no llega a AI ACTIVE.
4. Configurar un minuto de espera; comprobar que cada interacción retrasa la activación y que ningún agente cancelado vuelve a ejecutarse.
5. Medir con Instruments la latencia desde evento hasta inicio de interrupción (objetivo <100 ms) y verificar separadamente el descenso de memoria con un modelo cargado. El menú informa tiempo de terminación comprobada, no una medición de devolución de páginas de RAM al sistema.

## Límites del MVP

No se adopta ni se termina un Ollama externo. Los procesos que deliberadamente abandonen su grupo (`setsid`/daemonización), procesos remotos o runtimes que usen otros proveedores quedan fuera del control del grupo; configurar runtimes en primer plano. Tras un cierre forzado/crash no se matan PIDs de sesiones anteriores: no se puede asumir que sigan siendo propios. El cierre normal siempre termina primero los procesos administrados y se cancela si no puede verificarlo.

Quedan para P1 los adaptadores específicos MLX/llama.cpp/OpenCode/Hermes, perfiles múltiples, edición de entornos/secretos con Keychain, selección de pantallas y estadísticas avanzadas. En el MVP, todos los tipos de entrada y la terminación forzada permanecen habilitados para preservar Human First.

## Release local y permisos

El cambio de nombre usa una identidad nueva (`com.jfzepeda.Napkin`); los permisos de macOS deben concederse de nuevo y las preferencias de la versión anterior no se transfieren automáticamente.

El producto, ejecutable, nombre visible y bundle son `Napkin`, `Napkin`, `Napkin` y `com.jfzepeda.Napkin`. El icono incluye todas las resoluciones de macOS. La carpeta `dist` contiene el Release universal firmado con Apple Development para uso local; **no está notarizado ni firmado con Developer ID para distribución pública**.

Usar una sola copia instalada de `Napkin.app`, preferentemente en `/Applications`, y conceder permisos a esa copia. No alternar entre builds sin firma de pruebas y la copia firmada: macOS puede identificar sus requisitos de firma de forma diferente. Si sigue apareciendo una entrada de la versión anterior, quitar esa entrada desde Ajustes y añadir la copia actual de Napkin. Si macOS pide salir y abrir de nuevo, hacerlo. No es necesario borrar globalmente los permisos de otras apps.

Start cierra el panel y comienza el arranque; soltar el clic o tecla de inicio ya no lo cancela. Una **nueva** interacción (incluido movimiento del puntero) sigue interrumpiendo por diseño Human First. Stop bloquea el gateway inmediatamente y muestra Stopping hasta comprobar la terminación. Detener no desactiva la opción Automatic activation: reinicia su plazo de inactividad.

Los builds Debug y el host de pruebas usan `com.jfzepeda.Napkin.debug` (Napkin Debug), separado del Release. Si macOS conserva un permiso de una compilación antigua sin firma, el interruptor puede aparecer activado aunque TCC rechace el código actual; cerrar la app, restablecer únicamente `tccutil reset Accessibility com.jfzepeda.Napkin`, reabrir la copia firmada y autorizarla de nuevo resuelve ese registro obsoleto. Esto revoca solo ese permiso de Napkin y requiere concederlo otra vez manualmente.
