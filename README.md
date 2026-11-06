# Raw8KCam — Cámara Bayer RAW (.DNG) + Video 8K para iPhone 16

Aplicación nativa de cámara profesional en Swift / `AVFoundation` / `Metal` / `VideoToolbox` diseñada para desbloquear capacidades físicas ocultas del sensor de **48 MP (`8064 × 6048`)** y del chip **A18** del iPhone 16.

---

## Los 3 Modos Incluidos

1. **`RAW .DNG` (Fotografía Bayer RAW pura):**
   * Dispara directamente en formato **`.DNG` Bayer RAW (12/14 bits)** usando `AVCapturePhotoOutput.availableRawPhotoPixelFormatTypes`, saltándose el procesado artificial (*Deep Fusion* / *Smart HDR*) que la app Cámara nativa de Apple obliga a usar en el iPhone 16 base.
   * Guarda el archivo `.DNG` directo en tu app **Fotos**.

2. **`8K FLUIDO` (Open Gate `4032 × 3024` → Metal GPU 8K `7680 × 4320` a 30/60 fps):**
   * Activa el formato completo **Open Gate 4:3 (`4032 × 3024` = 12.2 MP por cuadro)** del sensor a **30 o 60 fps** con sonido en vivo.
   * Procesa cada cuadro en la GPU con **Metal (`CIContext` + realce óptico de luminancia)** y lo codifica por hardware mediante `VideoToolbox` / `AVAssetWriter` en un archivo **`.MOV` 8K (`7680 × 4320`) HEVC a 120 Mbps**.

3. **`8K 48MP PURO` (El truco del iPhone 5s / *Vizzywig* con el sensor de 48 MP):**
   * Configura el sensor en resolución física completa de **48 Megapíxeles (`8064 × 6048`)** con `photoQualityPrioritization = .speed` (apagando la latencia de *Deep Fusion*).
   * Captura una ráfaga continua de cuadros de 48 MP, recorta el área central **1:1 de `7680 × 4320` píxeles reales sin reescalar** y los empaqueta en un video **8K HEVC (`.MOV`)**, ya sea en cadencia de tiempo real (~15–20 fps) o como **Hyperlapse / Timelapse 8K a 30 fps**.

---

## Controles Manuales en Pantalla
* **Exposición Manual:** Control deslizante de **ISO** (`minISO`–`maxISO` reales del sensor) y botones rápidos de **Velocidad de Obturación** (`1/2000s` a `1/4s`).
* **Enfoque Manual:** Bloqueo de posición física de la lente (`0.00` macro a `1.00` infinito).
* **Selector de Lentes:** `1x (26mm 48MP)` y `0.5x (13mm Ultra Gran Angular)`.
* **Telemetría en Vivo:** Histograma de luminancia de 32 bandas en tiempo real, resolución activa del sensor, medidor de FPS y contador de fotogramas 8K grabados.

---

## Cómo compilar e instalar en tu iPhone 16 (Sin instalar Xcode en tu Mac)

1. Sube esta carpeta `Raw8KCam/` a un repositorio de **GitHub** (puede ser privado o público).
2. Ve a la pestaña **Actions** en GitHub y ejecuta el flujo **"Compilar Raw8KCam IPA"**.
3. En ~2 minutos terminará y podrás descargar **`Raw8KCam.ipa`** en la sección *Artifacts*.
4. Abre **Sideloadly**, **SideStore** o **AltStore**, arrastra `Raw8KCam.ipa`, fírmalo con tu Apple ID gratuito e instálalo en tu iPhone 16.

*(Si más adelante instalas Xcode en tu Mac, solo corre `brew install xcodegen && xcodegen generate` dentro de `Raw8KCam/` para abrir `Raw8KCam.xcodeproj` y darle a Run directo a tu iPhone por cable USB-C).*
