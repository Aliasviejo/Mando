# Mando

**Volume and brightness keys that just work on an external monitor or TV connected to your Mac by HDMI or DisplayPort.** Free and open source.

*Teclas de volumen y brillo que funcionan con un monitor o TV conectado a tu Mac por HDMI o DisplayPort. Gratis y de código abierto. [Español abajo](#español).*

---

## The problem

When a Mac sends audio over HDMI/DisplayPort, macOS treats it as fixed volume: the volume keys show a crossed-out speaker. The brightness keys do nothing on most third-party displays either.

Existing workarounds change the volume **on the monitor itself** over DDC. That makes the monitor pop its own on-screen volume bar every time and moves the monitor's global volume.

## What Mando does

- **Volume, the Mac way.** Mando installs a tiny virtual audio device with a real volume control. Audio goes through it and on to your HDMI device. The volume keys change the Mac's volume and show the classic macOS bezel. The monitor's volume stays where you set it and acts as a ceiling, and the monitor never shows its own bar.
- **Brightness over DDC/CI.** The brightness keys change the monitor's real backlight and show the native macOS bezel. Hold <kbd>⇧</kbd><kbd>⌥</kbd> for finer steps.
- **Automatic.** Pick your monitor as the output and Mando wraps it. Pick speakers or AirPods (devices that already have volume) and Mando gets out of the way.
- **Menu bar.** Volume and brightness sliders, an output picker and launch at login.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon recommended (DDC brightness uses the Apple Silicon display services). The audio part also works on Intel.
- Brightness needs a monitor with DDC/CI enabled. Some monitors accept DDC commands but can't report their current brightness over HDMI. Mando handles that and remembers the last value it set.

## Install

1. Download `Mando.zip` from [Releases](../../releases) and unzip it.
2. Run `scripts/install.sh`. It asks for your password to install the audio driver in `/Library/Audio/Plug-Ins/HAL` and restarts CoreAudio.
3. Grant the permissions macOS asks for:
   - **Accessibility**, to read the brightness and volume keys.
   - **Microphone**, because Mando reads its *own* virtual device to forward the audio. It never touches your real microphone.

If you use MonitorControl, FineTune, SoundSource or similar apps, quit them so they don't fight over the keys.

### Uninstall

```bash
./scripts/uninstall.sh
```

## Build from source

You need Xcode (or the Command Line Tools).

```bash
./scripts/build.sh          # ad-hoc signed, for local use
./scripts/install.sh
```

Release build, signed and notarized:

```bash
SIGN_ID="Developer ID Application: Your Name (TEAMID)" VERSION=0.1.0 ./scripts/build.sh
```

## How it works

```
apps ──▶ Mando (virtual device, volume applied) ──loopback──▶ Mando.app ──▶ HDMI monitor
                          ▲                                    (private aggregate device,
                 volume keys / macOS                            clock = monitor, drift-corrected)
```

- `Driver/MandoDriver.c` is a CoreAudio AudioServerPlugIn. It publishes an output device with volume and mute controls and applies the gain to the mix. It loops the result back to its input side.
- `App/Sources/AudioRouter.swift` builds a private aggregate device: the monitor is the clock master and Mando is drift-compensated. `App/Bridge/Router.c` copies the loopback into the monitor's output on the real-time thread.
- `App/Sources/DDC.swift` talks DDC/CI (VESA MCCS, VCP `0x10`) through `IOAVService`.
- `App/Sources/MediaKeys.swift` is a `CGEventTap` that handles the media keys.

Thanks to [MonitorControl](https://github.com/MonitorControl/MonitorControl) (MIT) for documenting DDC on Apple Silicon.

## License

[MIT](LICENSE) © Aliasviejo

---

## Español

### El problema
Cuando la Mac manda el audio por HDMI o DisplayPort, macOS bloquea el volumen y las teclas no hacen nada. Las apps que existen cambian el volumen **del monitor** por DDC. Por eso el monitor muestra su propio indicador encima cada vez.

### Qué hace Mando
- **Volumen como en la Mac:** un dispositivo de audio virtual con volumen real. Las teclas mueven el volumen de macOS con su indicador clásico. El volumen del monitor queda fijo como tope, y el monitor no muestra su indicador.
- **Brillo por DDC/CI:** las teclas de brillo cambian el brillo real del monitor, con el indicador de macOS. Con <kbd>⇧</kbd><kbd>⌥</kbd> los pasos son más finos.
- **Automático:** si eliges el monitor como salida, Mando se encarga. Con parlantes o AirPods se hace a un lado.

### Instalar
1. Descarga `Mando.zip` de [Releases](../../releases).
2. Ejecuta `scripts/install.sh`. Te pide la contraseña para instalar el driver de audio.
3. Acepta los permisos de **Accesibilidad** (para las teclas) y **Micrófono**. Mando solo lee su propio dispositivo virtual; nunca accede a tu micrófono real.

Si usas MonitorControl, FineTune o SoundSource, ciérralas para que no peleen por las teclas.
