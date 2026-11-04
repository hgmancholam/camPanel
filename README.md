# CamPanel

Panel de configuración para cámaras UVC en macOS, con presets guardables y reaplicación
automática al iniciar sesión.

Nace porque CameraController 1.4.0 (último release en 2022) muestra todos los controles
deshabilitados en macOS 26, aunque la cámara sí los expone.

## Cómo funciona

App nativa SwiftUI. No habla USB por su cuenta: usa `uvcc` como motor, que es lo que
demostró funcionar contra el hardware.

El bundle es autocontenido. Dentro de `Contents/Resources` viajan el binario de `node` y
uvcc con sus dependencias, así que la app no necesita npm, ni nvm, ni un `PATH` heredado.
Verificado con `env -i`, sin ninguna variable de entorno. Si algún día borras ese motor
embebido, la app cae de vuelta a buscar un `uvcc` instalado en el sistema.

Ese precio se paga en disco: el binario de node son 116 MB de los 128 MB del `.app`.

- Lee `uvcc devices`, `uvcc export` y `uvcc ranges` al abrir
- Un slider por control con rango, un menú por control de modo, un switch por control 0/1
- Cada cambio se escribe con `uvcc set` al soltar el control
- Los presets se aplican con `uvcc import` en una sola llamada (~150 ms)

## Requisitos

- macOS 13 o superior, Apple Silicon
- Nada más en tiempo de ejecución

Para compilar sí hacen falta las herramientas de línea de comandos de Xcode y `npm`, que
solo se usa durante el build para bajar uvcc dentro del bundle.

## Compilar

    ./build.sh                                       # deja build/CamPanel.app
    ./build.sh /Applications/CamPanel.app            # compila e instala
    ./build.sh build/CamPanel.app --no-embed         # sin motor embebido, usa el del sistema

## Dónde vive el estado

`~/Library/Application Support/CamPanel/`

| Archivo | Contenido |
|---|---|
| `config.json` | presets por modelo de cámara, valores iniciales, preset de arranque |
| `login-<vid>-<pid>.json` | preset que se reaplica al iniciar sesión |
| `login-<vid>-<pid>.sh` | script generado, reintenta 20 veces cada 3 s |
| `login.log` | salida del arranque automático |

El LaunchAgent se registra como `~/Library/LaunchAgents/local.campanel.<vid>-<pid>.plist`.
El script generado apunta al motor dentro del `.app`, así que si mueves o borras la
aplicación, desactiva antes la casilla de arranque automático.
Los reintentos existen porque una cámara detrás de un dock puede tardar en enumerar
después del arranque.

Los presets se guardan por modelo (vendor + product), no por puerto, así que sobreviven a
un cambio de puerto USB o de dock.

## Notas de UVC

El orden de escritura importa: los modos automáticos se apagan antes de fijar el valor
manual correspondiente. Por eso `auto_white_balance_temperature` se aplica antes que
`white_balance_temperature`, y `auto_exposure_mode` antes que `absolute_exposure_time`.

"Restaurar valores iniciales" devuelve la cámara al estado que tenía la primera vez que la
app la leyó, no a un default de fábrica: UVC no expone GET_DEF por esta vía.
