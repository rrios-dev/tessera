# Plan v4: gestor de ventanas en mosaico para macOS (nombre provisional **Tessera**)

> **Revisión 4.1.** Cuatro rondas de auditoría. Rondas 1–3: producto/HIG, plataforma y QA (112 hallazgos, todos trazados). **Ronda 4, ingeniería:** cada afirmación técnica verificada contra los headers del SDK 26.0 y con **sondas ejecutadas en el Mac del usuario**; el executor, el solver y los pesos **compilados y probados** con 200k–2M casos aleatorios; alcance dimensionado en líneas de código frente a AeroSpace. Resultado: 2 afirmaciones falsas corregidas, el solver y los pesos reescritos con algoritmos probados, tres permisos que faltaban en el presupuesto, y una estimación honesta del calendario. **Decisiones del usuario tras la ronda 4:** soporte de **cualquier disposición de monitores** con comunicación cuidada por configuración; **plan completo**, sin recorte MVP; laboratorio en **su propio Mac Studio** con varios monitores.

## 0 · Contexto

El usuario trabaja con monitores verticales. AeroSpace a veces corrompe la disposición y deja **huecos vacíos**. Queremos una app propia de calidad excepcional: mosaico vertical y horizontal, varios escritorios con su propio layout, escritorios maximizados, fluidez, consumo mínimo y configuración visual comprensible.

**Principio rector.** "Sin huecos" se **mide en pantalla** (marcos reales del WindowServer) y el detector se **calibra contra píxeles** para no comprobarse a sí mismo.

### 0.1 Estado real del Mac del usuario (medido el 2026-09-25)

| Dato | Valor medido | Consecuencia |
|---|---|---|
| Sistema | macOS 26.6.2 (25G83), Mac Studio M2 Max, Xcode 26.0.1, Swift 6.2 | Sin pantalla integrada: clamshell y notch son solo de laboratorio |
| Pantallas conectadas | **1** en el momento de la medición: LG Ultrawide 2560×1080 girado 270° → **1080×2560 pt, escala 1.0, 75 Hz**; en el historial de Spaces aparece **una segunda pantalla** (`96496A44…`). El Mac Studio M2 Max admite **hasta 5 pantallas** (4 Thunderbolt + 1 HDMI) | El usuario conectará varios monitores para S2 y el Gauntlet (§12); el producto debe soportar **cualquier disposición** (§6.1) |
| Área útil | Barra de menú 30 pt; Dock abajo, 82 pt, sin auto-ocultar | Fixture n.º 1 parcial ya capturado |
| Spaces | "Displays have separate Spaces" **activado**; la pantalla principal tiene **2 Spaces: 1 escritorio + 1 pantalla completa nativa** | La regla de onboarding "> 1 Space" **no debe contar** los Spaces de pantalla completa (tipo 4) |
| Stage Manager | Desactivado (se usó alguna vez); tiling nativo desactivado; agrupar por app: no | — |
| Teclado | **Spanish-ISO** | Preset Ctrl+Option; el remapeo del importador es central |
| AeroSpace | **0.20.3-Beta en ejecución**; config con **72 de 81 atajos en solo-Option** (31 `alt-`, 41 `alt-shift-`), gaps 0, layout `tiles`, orientación `auto`, sin `on-window-detected` | El importador remapea casi toda la config; el hotkey "veo un hueco" del modo sombra no puede colisionar con esos 81 |
| Accesibilidad | VoiceOver y opciones de pantalla desactivadas; sin Secure Input | — |
| Ventanas | 143 en `optionAll`, 88 en capa 0, 26 pids | Volumen realista para el auditor |

### 0.2 Decisiones cerradas

| # | Decisión |
|---|---|
| D1 | **Repo propio nuevo**, fuera del monorepo Forge. |
| D2 | **Reescritura con referencia.** Se portan con atribución (MIT, `NOTICE`) las heurísticas de diálogos de AeroSpace y sus **125 dumps AX** (commit `5f08f9c`). Fixtures propios de pestañas y Tahoe. |
| D3 | **Escritorios emulados mejorados.** Sin SIP ni SkyLight para el layout. |
| D4 | **GUI + TOML** sincronizados en ambos sentidos con **CST sin pérdidas** (conserva comentarios y formato). Hasta que el CST esté listo (fase 5), la GUI es dueña de `tessera.toml` y las ediciones a mano viven en `tessera.local.toml` (overlay de solo lectura); ese modo intermedio se retira al cerrar la fase 5. |
| D5 | **Swift 6.2**, concurrencia estricta, **macOS 15.2+, arm64 y x86_64**. Verificado en el toolchain: `isIsolatingCurrentContext` (SE-0471, `@available(macOS 26)`) **es el camino primario en 26** (el runtime lo invoca y no llama a `checkIsolated`); `checkIsolated()` (SE-0424, macOS 15) es el camino en 15.x. **Ambos obligatorios; S3 prueba los dos.** Que 15.2 restauró los atajos solo-Option se **verifica en S4** sobre un volumen externo con 15.2 (el Mac Studio M2 Max, lanzado con macOS 13.4, puede arrancarlo). x86_64 se cubre en CI alojada (Core/Config/fakes) y con una máquina Intel prestada antes del release. |
| D6 | **Sin App Sandbox.** Developer ID + Hardened Runtime + notarización. Bundle ID y equipo **inmutables**. Firma estable también en desarrollo. |
| D7 | **APIs privadas en producción:** `_AXUIElementGetWindow` (verificado en `HIServices.tbd`) y, si S7 lo justifica, `_SLPSSetFrontProcessWithOptions` + `SLPSPostEventRecordTo` (verificados por `dlsym`). Aisladas tras `FocusPort`. `CGVirtualDisplay` (verificado) **solo en el harness**. `AXEnhancedUserInterface` es un literal privado sin header. |
| D8 | **Monocle híbrido:** 2 ventanas MRU apiladas al área; el resto oculto. Si S2 demuestra que no hay esquina segura a tamaño completo, puede encoger antes de minimizar. |
| D9 | **Dos procesos, un bundle:** `Tessera.app` (motor, `LSUIElement`, único con AX) y `Contents/Applications/Tessera Settings.app`. Rol por lanzador: si `XPC_SERVICE_NAME == <label>` es el agente; cualquier otro lanzamiento hace `SMAppService.register()` si `.notRegistered`, `launchctl kickstart gui/$UID/<label>` si `.enabled` y no corre, abre Settings (salvo `handoff=true` en el journal) y sale. |
| D10 | Código y documentación en inglés. Interfaz en español e inglés. |
| D11 | **Plan completo en un solo programa** (decisión del usuario tras el dimensionamiento de §13): se aceptan **57–80 semanas, P50 ≈ 66**, con hitos internos comprobables y un checkpoint de uso diario en la semana ~22 que **no recorta alcance**, solo re-secuencia. |
| D12 | **Cualquier disposición de monitores es de primera clase** (1 vertical, 1 horizontal, 2 verticales, 2 horizontales, vertical + horizontal en cualquier posición relativa, 3 o más mixtos, escalas distintas). Cada disposición es un **perfil independiente** (§6.1) con comunicación clara al usuario de qué ha pasado y qué hará Tessera. |
| D13 | **Laboratorio = el Mac Studio del usuario** con los monitores que conecte, más una cuenta de usuario de laboratorio y un volumen externo con macOS 15.2 (§12). Sin MDM: los permisos TCC se conceden a mano una vez por cuenta y persisten gracias a la firma estable. |

## 1 · Causas raíz en AeroSpace → diseño que las elimina

| Causa verificada | Diseño nuevo |
|---|---|
| `setFrame` dispara y olvida (`MacApp.swift:411`); ignora mín/máx (#121). | Bucle cerrado con lectura del marco real, facts con confianza y estados terminales (§4.4). |
| Pesos en píxeles, reparto aditivo, el solver los reescribe. | Pesos ppm con **restos mayores** (probado: suma exacta); **el solver es puro** (I5b). |
| `height - 1` sin documentar (`layoutRecursive.swift:9-11`). | Modelo de clamp medido en S2 y cargado en los fakes. |
| Orientación `auto` fijada al crear el escritorio. | Se resuelve en cada solve según el aspecto del monitor. |
| Arrastre mal atribuido. | Sesión de arrastre + generación; confirmación al soltar. |
| Fantasmas (#68, #943, #1257, #1979). | Vida por CGWindowList + AX (§5); pestañas por `AXTabGroup`. |
| Sin `AXUIElementSetMessagingTimeout`; el refresco espera a todas las apps (#1615). | Timeout global fijado una vez + por ref cacheado; sin cancelaciones. |
| Sin callback de pantallas; monitor = punto de origen (#506). | UUID con desempate; diff de topología. |
| Oculta en esquina a tamaño completo (#2102). | HidePlanner con clamp medido, último recurso y journal. |
| Solo SIGTERM/SIGINT. | Journal WAL + LaunchAgent + rescate + modo seguro (§8). |
| Árbol mutable (#1215). | `World` inmutable + reducer puro. |

## 2 · Arquitectura

### Targets SwiftPM

| Target | Contenido |
|---|---|
| `TesseraCore` (solo stdlib) | Geometría entera en **puntos**, `World`, solver, modos, orientación, HidePlanner, asignación, máquina de estados, reducer, `Invariants`. |
| `TesseraConfig` | CST TOML sin pérdidas (fase 5; antes, librería + overlay local), esquema, migraciones, **mapeo AeroSpace → Settings** con remapeo ES-ISO. |
| `TesseraPlatform` | `AppAgent`, auditor, topología, hotkeys Carbon, taps, observadores, foco. |
| `TesseraFakes` | `FakeWindowServer` con reloj virtual, modelo de clamp, carga del fixture n.º 1. |
| `TesseraEngine` | Bomba de eventos, `Store`, reconciliador, verificador I9, journal, persistencia, IPC. |
| `TesseraIPC` | Contrato motor ↔ CLI (socket) y motor ↔ Settings (**XPC**). |
| `tessera` (CLI) · `TesseraApp` · `TesseraSettingsApp` · `TesseraHarness` + `DummyWindowApp` + `PixelCheck` | — |

### Concurrencia (verificada con sonda compilada en `-strict-concurrency=complete`)

- **`AppAgent`**, un actor por pid con `SerialExecutor` propio (Thread + `CFRunLoop`; `enqueue` = `CFRunLoopPerformBlock` + `WakeUp`). Implementa **`isIsolatingCurrentContext()`** (con los diagnósticos) y `checkIsolated()`. Medido: **27 KB residentes por agente** (100 agentes ≈ 2,7 MB).
- **Reglas duras (todas verificadas por trap en la sonda):**
  - Los callbacks C son `@convention(c)` o funciones `nonisolated`; **nunca closures formados en contexto `@MainActor`** y ejecutados en el hilo del agente (trap en `dispatch_assert_queue`).
  - Refcon con **`passRetained`**, liberado tras `CFRunLoopSourceInvalidate` y la salida del run loop.
  - **Prohibido anidar el run loop** dentro de un job del agente.
  - Los tipos CF/AX no son `Sendable`: envoltorios `@unchecked Sendable` confinados; el compilador hace cumplir que los `AXUIElement` no salen del agente.
- **Timeouts AX** (`AXUIElement.h:389-393`): el **global de 1,5 s se fija una vez al arrancar** en el elemento systemwide (es global al proceso; no se cambia en caliente). Los **350 ms** se fijan en cada `AXUIElementRef` de ventana **cacheado**; un ref re-obtenido de `kAXWindowsAttribute` vuelve al global. `unresponsive` tras 3 fallos seguidos en > 1 s; backoff reseteado al primer éxito; escrituras coalescidas por ventana; sus ventanas quedan `pending` y fuera de I9; **si están ocultas, permanecen ocultas hasta que la app responda** (evita un hueco visible).
- **`Store`** (MainActor): reducer puro < 1 ms.
- **Bomba de eventos:** lotes cada 8 ms, espera máxima 16 ms. **Los hotkeys se saltan el lote** (despacho inmediato). Sin cancelaciones; generación invalida pasadas en vuelo.

### Flujo cerrado

```
evento → reduce → World' → solve(World', Topology, Facts, UsableArea) → LayoutPlan
       → diff → apply por app en paralelo (serie dentro de cada app; visibles primero; generación)
       → settle → FactLearner → re-solve (≤3 pasadas/época) → verificador I9 (calma por ventana)
```

**Época** = aplicaciones derivadas de un mismo `World'`; termina al evaluar I9 o al alcanzar un estado terminal.

## 3 · Modelo, escritorios, layouts, estados

### Árbol

- `Workspace { name, homeMonitor, layouts, activeLayout, orientationOverride?, overflow, floating, mru, dynamic }`.
- `LayoutMode` = `tiles` | `accordion` | `monocle` | `master-stack` | `dwindle` | `scroll` (reservado para una versión posterior).
- `Container { axis, kind, children: [(node, weight ppm)] }`. Sin punteros al padre; normalización pura e idempotente.
- `cycle-layout` manual gana sobre el override por orientación hasta el siguiente cambio de orientación. Escritorios dinámicos `~<bundle>` / `~m<n>` direccionables.

### Pesos ppm (algoritmo probado: 50 inserciones, suma exacta, n=51)

- **Insertar:** objetivos exactos `wᵢ·(n−1)/n` y `10⁶/n`, redondeados por **restos mayores** (desempate por índice). La regla ingenua "truncar" rompe la suma en el 83 % de los casos (medido).
- **Suelo** `min(5 %, 1/(2n))` aplicado por **llenado de agua**: subir al suelo, restar proporcionalmente del resto, restos mayores.
- `balance-sizes` = `10⁶/n` con restos mayores. `resize` mueve peso entre el par adyacente.
- **Solo mutan pesos:** `resize`, soltar arrastre, `balance-sizes`, edición del árbol (**I5b**).

### "Escritorio maximizado"

1. `monocle` (D8). **I19:** entre las `tiled`, exactamente una es frontal con bounds = área útil; como máximo otra con los mismos bounds justo debajo; el resto cumple I7; flotantes fuera.
2. `fullscreen` / `zoom` como flags del plan; hermanos tapados enteros debajo u ocultos.
3. Regla "abrir en escritorio propio maximizado" → escritorio dinámico `monocle`.

### Estados de una ventana (I10)

`tiled` · `floating` · `autoFloated` (flag derivado, no cambia el árbol) · `hidden(byTessera, method)` · `minimized` · `appHidden(byUser)` · `nativeFullscreen` · `offSpace` · `unmanaged`. `sticky` implica flotante.

### Flotantes · Undo · Extras

Como v3.1: rect relativo, dentro del área (I13 con excepción sobredimensionadas), re-elevadas best effort tras cada cambio de foco (medido en S7); undo solo de intención de layout; scratchpad, sticky, marks, `workspace-back-and-forth`, `summon-workspace`.

### Máquina de estados de la app

| Estado | Ventanas ocultas | Salida |
|---|---|---|
| **Activo** | Gestionadas | — |
| **Pausado** (menú ✓, Stage Manager) | Se quedan; "Reunir todas las ventanas" disponible | Quitar ✓ / desactivar SM |
| **Sin permiso** | Se quedan; "Reunir" deshabilitado y explicado; al recuperar el permiso se restauran solas | Restaurar permiso |
| **Detenido** | Restauradas; el **proceso sigue vivo** | "Reanudar tiling" |
| **Modo seguro** (3 crashes / 5 min) | Restauradas; sin tiling | "Reintentar" |
| **Actualizando** (Sparkle) | `handoff=true` en el journal; salida 0 sin restaurar | Relanzamiento |
| **Saliendo** (Salir → 0; SIGTERM de launchd sin `handoff`; `willPowerOff`) | Restauradas | — |

**Salida 0 solo en Salir y Actualizando.** `KeepAlive = { SuccessfulExit = false, Crashed = true }` (implica `RunAtLoad`), `ThrottleInterval = 5`, `ExitTimeOut` explícito (verificado en `man launchd.plist`). Al salir de Pausado/Sin permiso y tras cada cambio de topología se ejecuta el **barrido de rescate** (§8). Prioridad de icono: Modo seguro > Sin permiso > Stage Manager > Detenido > Pausado > Actualizando > Secure Input > Marca I9 > Modo de atajos > Normal.

## 4 · Solver y reconciliación

### 4.1 Área útil

`visibleFrame` re-leído en `didChangeScreenParameters`, cambio de Space, activación de app y cada fallo de I9; S8 fija la fuente para el Dock saltando de pantalla o adopta un sondeo de 1 s durante actividad. Margen reservado por monitor; gaps; smart gaps.

### 4.2 Algoritmo (entero, en puntos; **corregido tras 200k árboles aleatorios**: la versión v3 violaba I1 en 1.860 niveles e I3 en 29.690)

1. **Medir** (abajo→arriba). Hojas: `min` redondeado **hacia arriba** y `max` **hacia abajo** a la rejilla del cuanto. Eje principal: `min = Σmin + gaps`, **`max = Σmax + gaps`**. Eje cruzado: `min = max(minᵢ)`, `max = min(maxᵢ)`. Si el intervalo cruzado es vacío → `autoFloated` la hija con mayor déficit y re-medir (≤ n veces).
2. **Distribuir** (arriba→abajo), bucle "resolve flexible lengths" de CSS en enteros: cada iteración reparte `free·wᵢ/W` con **restos mayores dentro del bucle**; se congelan los que violan (todos los de mínimo si la violación total > 0, todos los de máximo si < 0); **≤ n iteraciones** (medido: máx. exactamente n); la suma es exacta por construcción. **Sin re-clamp posterior** (con cotas enteras es innecesario y con cotas no enteras abre huecos de 1 pt).
3. **Cuantos:** ajustar hacia abajo a la rejilla; el resto va a hermanos no cuantizados **con holgura hasta su máximo** (el más cercano primero); lo que sobre queda como slack dentro del propio tile (≤ q−1, **I1b**). Un subárbol es flexible en un eje si: principal → alguna hija lo es; cruzado → **todas** lo son.
4. **Underfill** (`Σmax < disponible`): estado declarado; el sobrante va a los bordes exteriores.
5. **Overflow** (`Σmin > disponible`): contenedor infactible más profundo hacia arriba; políticas `accordion` (≤ 4 franjas; exceso a `stack`), `stack`, `float-largest`, `allow`.
6. **Aspecto** (Simulator, emulador): **el tamaño principal se deriva del cruzado**, `round(cruzado·r)`, como min=max entero (la dirección inversa dejaba huecos de 528 pt en una columna de 1080). Si no cabe → absorbedor → `autoFloated`. Un aspecto anidado necesita **un re-solve por ventana de aspecto**.
7. Ventana con mínimo mayor que el monitor → `autoFloated`, sobredimensionada, avisada.
8. **Desempate** de `autoFloated`: mayor déficit → más nueva → menor CGWindowID.

Resultado del algoritmo corregido: **300k árboles, I1 = 0, I3 = 0, I1b = 0 violaciones; 2M casos del bucle aislado, 0 fallos.** El pseudocódigo va en `Solver.swift` y cada paso tiene su test de propiedad.

### 4.3 WindowFacts

Clave `(bundleId, versión, subrole, firma AX, backingScale)`, TTL 30 días. Facts: `minSize`, `maxSize`, `quantum`, `aspectRatio`, `fixedSize`, `selfResizing`. Pistas previas (confianza 1): `AXUIElementIsAttributeSettable(kAXSizeAttribute)` y zoom deshabilitado (fiables en AppKit, no en Electron/Qt/Java). Aprendizaje con 2 lecturas idénticas separadas ≥ 1 settle; nunca oculta, encogida ni en animación. Invalidación tras 2 contradicciones seguidas. Visibles y reseteables.

### 4.4 Reconciliación

Estados por ventana: `Settled → Writing(g) → AwaitSettle(g) → Observed → {Converged → Watch(2 s) → CalmCandidate → I9 | Mismatch → (pasada < 3 ? Learn → ReSolve → Writing(g+1) : HardConstraint → ReSolve(resto) → ¿infactible? AutoFloated)}`.

1. Escritura **tamaño → posición → tamaño** etiquetada por generación. Con VoiceOver activo (comprobado en caliente) no se toca `AXEnhancedUserInterface`; apps tocadas al journal.
2. **Settle y emparejamiento:** las notificaciones no traen marco; se empareja el **marco leído** contra **todos los marcos intermedios** de cada generación en vuelo (p. ej. posición vieja + tamaño nuevo). "Posición planificada con tamaño distinto" es **restricción**, no deriva. Emparejar la generación g **retira todas las ≤ g**; una ventana solo queda `Settled` al emparejar la **última** generación o al confirmarla una re-lectura tras su plazo.
3. ≤ 3 pasadas por época.
4. **Terminal:** (a) restricción dura con el marco observado, **vigencia con backoff exponencial 60 s → 5 min → 30 min**, o hasta una intención del usuario **que toque su contenedor**; (b) si sigue infactible → `autoFloated`.
5. **Vigilancia de 2 s** con presupuesto **2 re-solves por ventana / 10 s** y **≤ 6 por escritorio / 10 s**; agotado → restricción dura + `selfResizing`. Una ventana `selfResizing` **solo actualiza su propio tile**, nunca re-resuelve a los vecinos.
6. **Verificador I9 con calma por ventana:** a los 2,5 s se evalúan las ventanas en calma y el resto queda `unverified`; si un monitor pasa > 10 s sin evaluación completa se evalúa excluyendo las no calmadas y se registra `calmStarvation`. Las escrituras a apps colgadas **no cuentan como en vuelo**. Ante violación: 1 reintento, traza, marca.

### 4.5 Invariante I9 (por ventana y por modo)

Como v3.1 (conjunto = `tiled`; marco observado = planificado; costuras exactas en puntos, comparadas en píxeles de backing con escala fraccionaria; tolerancia solo en bordes exteriores según S2; I2 solo en modos de partición; variantes por modo; remanentes excluidos). **PixelCheck** con máscara (esquinas de Tahoe, sombras, gaps, slack/underfill) calibra precisión y exhaustividad; con gaps = 0 (caso del usuario) la máscara es mínima.

## 5 · Ciclo de vida y convivencia con macOS

### Vida de una ventana

- **Muerta ⇔ su CGWindowID no está en `optionAll`**, sea cual sea el pid (regla simple y probada: `optionAll` incluye minimizadas y de apps ocultas).
- **Viva pero fuera del árbol** si está en `optionAll` y no en `AXWindows` ni en pantalla: es `offSpace` si desapareció de `AXWindows` **dentro de 1 s de un `activeSpaceDidChange` en su monitor** (S10 valida; alternativa privada `CGSCopySpacesForWindows` descartada por D3); si no, es una "cerrada que la app solo esconde" y **se retira del árbol** (libera el tile) aunque siga viva.
- Filtros del auditor: capa 0, alpha > 0, pid gestionado, **`kCGWindowIsOnscreen` (su ausencia = no en pantalla; verificado: solo 7 de 143 entradas lo traen)**. Pid ajeno → `unmanaged`.
- Auditorías dirigidas (~1 ms) en cada evento + ráfaga de 2 s tras eventos de app; reposo 30 s. Cota: cierre → tile liberado ≤ 2 s con actividad, ≤ 30 s en reposo.
- Títulos por AX. **S1 verifica con un binario sin Screen Recording** que Bounds/Layer/PID/Alpha siguen presentes (no pudo verificarse desde un proceso que ya tenía el permiso).

### Clasificación, pestañas, propias

Como v3.1 (primer match; `re-evaluate-on-title-change`; `AXTabGroup`; I17 por bundle/team ID).

### Políticas frente a macOS

| Situación | Política |
|---|---|
| Pantalla completa nativa | `nativeFullscreen`; vuelve al salir. **Los Spaces de pantalla completa (tipo 4) no cuentan** en la regla de onboarding "> 1 Space". |
| Otro Space nativo | `offSpace`; congelación solo de ese monitor. |
| Minimizar / Cmd-H del usuario | Fuera del tile; vuelve al restaurarse. Los iniciados por Tessera van etiquetados. |
| Tiling nativo macOS 15+ | Guía para desactivar; movimiento externo con sesión de arrastre = `move`; sin sesión = re-aplicar. |
| Stage Manager | Pausado + banner con botón a Escritorio y Dock; reanudación automática. |
| Secure Input | Indicador con culpable. |
| **Logout / apagado** | **`NSWorkspace.willPowerOff` + SIGTERM de launchd** (con `ExitTimeOut`). `sessionDidResignActive` es **cambio rápido de usuario**, no logout: congela, no restaura (contradicción de v3 corregida). |
| Reposo / bloqueo / FUS | Congelar; al volver, `NSScreen.screens` estable 500 ms tras cerrar `kCGDisplayBeginConfigurationFlag`; auditar; re-registrar hotkeys. |
| Foco en escritorio oculto | Cambiar a ese escritorio (opción `pull-window`). |

### Foco · Ratón

S7 (criterio en §12). Tap de ratón activo (permiso verificado en S4), hilo propio, callback < 100 µs sin tocar el `Store`. Redimensión por arrastre (zona = gap ± 6 pt), swap/reordenar con zonas de soltado, modificador+arrastre, focus-follows-mouse opt-in, mouse-follows-focus.

## 6 · Monitores y ocultación

### 6.1 Perfiles por disposición (D12)

- Una **disposición** = conjunto de identidades de monitor + posiciones relativas + orientaciones + escalas. Cada disposición tiene su **perfil**: asignación de escritorios por monitor, orientación por defecto, gaps, márgenes reservados, política de ocultación resultante y esquinas seguras calculadas.
- **Reconocimiento:** al cambiar la topología se busca el perfil que coincide (identidades + posiciones ± tolerancia); si coincide se aplica sin preguntar; si es nueva se crea desde el perfil más parecido y se informa.
- **Comunicación al usuario, siempre no modal** (OSD 3 s + entrada en Diagnóstico + VoiceOver):
  - "Se ha conectado *LG Ultrawide* (vertical, a la izquierda). Los escritorios 1–3 vuelven a él."
  - "Se ha desconectado *Dell U2720Q*. Sus escritorios 4–5 se muestran ahora en *LG Ultrawide*; volverán al reconectarlo."
  - "Disposición nueva detectada. Tessera usará la esquina inferior izquierda de *LG* para ocultar ventanas. Ajusta la disposición en Ajustes › Monitores."
  - Aviso explícito cuando una disposición **no tiene esquina segura** en algún monitor (y por tanto minimizará) o cuando dos monitores son indistinguibles.
- **Settings › Monitores** dibuja la disposición actual a escala, con etiqueta por monitor (nombre, orientación, escritorios, esquina de ocultación) y una lista de disposiciones conocidas para renombrarlas o borrarlas.
- **Matriz canónica de disposiciones**, usada en fakes (todas), en S2 y en el Gauntlet (subconjunto físico en el Mac del usuario): 1V · 1H · 2V lado a lado · 2H lado a lado · 2H apilados · V+H con la H a la izquierda / derecha / arriba / abajo · V entre 2H · 3 mixtos con una escala 2x · monitor principal vertical y horizontal · Dock en cada posición. Los fakes generan además combinaciones aleatorias de tamaños, escalas y desalineaciones (I7, I9, I14 en todas).

### 6.2 Identidad, topología, asignación

- **Identidad:** UUID (`CGDisplayCreateUUIDFromDisplayID`) + desempate vendor/model/serial → posición relativa → orden de conexión. `CGDisplayUnitNumber` **no se usa como clave**. `CGDisplayIOServicePort` está deprecado ("No longer supported"); S9 evalúa `DCPAVServiceProxy` (verificado que sus atributos `ManufacturerID/ProductID/SerialNumber` coinciden con CoreGraphics en el monitor del usuario). En macOS 26, `NSScreen.CGDirectDisplayID`.
- **Topología:** callback gated por `BeginConfigurationFlag` (flags verificados en `CGDisplayConfiguration.h:211-222`; requiere run loop activo) + `didChangeScreenParameters`. Retiradas: presentación re-alojada al instante; memoria de asignación 3–5 s. Altas a 150 ms. Espejos = 1.
- **Asignación** determinista (I14) como v3.1, resuelta dentro del perfil de la disposición activa.

### 6.3 HidePlanner

- **HidePlanner:** I7 (remanente ≤ k medido en S2, en su monitor hogar, esquina que no toque otro monitor). Orden: 4 esquinas → encoger → app-hide si todas sus ventanas están ocultas → **minimizar** (último recurso, avisado). Ya oculta no se reescribe. Journal antes de mover.

## 7 · Entrada, IPC y UI

- **Hotkeys:** Carbon (verificado en 26.6.2: `RegisterEventHotKey` devuelve 0 para opt, opt+shift, ctrl+opt, ctrl+opt+cmd, incluso con AeroSpace corriendo; **registrar ≠ recibir**: S4 mide la entrega 100/100). Presets: `Ctrl+Option`; con VoiceOver `Ctrl+Option+Cmd`. El **importador remapea los 72 atajos solo-Option** del usuario con aviso. Re-registro tras desbloqueo/despertar/cambio de input source.
- **Descubrimiento, switcher, bordes, barra de menú:** como v3.1 (HUD de atajos, switcher de texto, bordes de foco, menú HIG con estados).
- **IPC (corregido):**
  - **Settings ↔ motor por `NSXPCConnection`** con `MachServices` en el plist del agente y `setCodeSigningRequirement` fijando el team ID: launchd gestiona la vida de la conexión y no hay sockets huérfanos. Vista previa a 60 Hz: mensajes latest-wins.
  - **CLI por socket Unix 0600** con `getpeereid`; **los títulos se suprimen** salvo que el cliente pase la comprobación de firma (`LOCAL_PEERTOKEN`), porque `getpeereid` solo comprueba el UID y cualquier proceso del usuario leería títulos que requieren permiso propio.
  - CLI compatible con AeroSpace (campos y `--format`, no byte a byte), binario `aerospace` **opt-in y solo si no hay AeroSpace instalado**, `subscribe` para SketchyBar y similares.

## 8 · Robustez

- **LaunchAgent** `SMAppService.agent` (verificado: `register/unregister/status/openSystemSettingsLoginItems`; **no existe "start"** → `launchctl kickstart`). `.requiresApproval` → `openSystemSettingsLoginItems()`.
- **Journal (WAL + checkpoint):** registro `[len u32][crc32c u32][seq u64][payload]`, un único `write(2)` con `O_APPEND` y `flock`. Lectura secuencial; el primer registro inválido y lo que sigue se trunca. Sin `fsync` en caliente (los CGWindowID no sobreviven a un reinicio; `write` es duradero frente a la muerte del proceso). Compactación: `journal.tmp` → `fsync` → `rename` → `fsync(dir)`; **solo se descartan IDs ausentes de `optionAll`**. El `World` persistido guarda `lastJournalSeq`; al arrancar se reaplican los registros posteriores. Conflictos: el journal manda en estado de ocultación y marco original; el `World` en pertenencia al árbol; si el marco actual ≠ el oculto → movida externamente, no se restaura.
- **Arranque:** journal → re-adopción por CGWindowID → restaurar `AXEnhancedUserInterface` → **barrido de rescate** (< 20 % del área en pantalla → recentrar), repetido al lanzarse cada app, tras cada cambio de topología y al salir de Pausado/Sin permiso.
- **Permisos, logging, tabla de errores, copy de overflow, diagnóstico, uninstall (Papelera por vigilancia del bundle):** como v3.1.

## 9 · Configuración

- **Fases 2–4:** `tessera.toml` propiedad de la GUI (escritura atómica symlink-safe, backups) + `tessera.local.toml` a mano, de solo lectura para la GUI y con diagnóstico de línea si es inválido.
- **Fase 5 en adelante:** CST TOML sin pérdidas, sincronización bidireccional (FSEvents, filtro de eco, 20 backups, Cmd-Z), migraciones CST → CST con changelog, filas "editado en archivo", y retirada del overlay (migración automática de `tessera.local.toml` al archivo principal).
- Anti-bloqueo (GUI y archivo) con revert a 15 s. Reglas con primer match y `re-evaluate-on-title-change`.
- **GUI completa:** Monitores (vista previa con solver real + disposiciones conocidas, §6.1), Escritorios (layouts, ciclo, override por orientación, overflow con copy llano y vista previa, hogar), Atajos (grabador con `UCKeyTranslate`, conflictos con propios y símbolos del sistema, preset por distribución y VoiceOver), Reglas (bundle, regex de título, rol/subrol; flotar, escritorio, monitor, layout, maximizada, scratchpad, sticky, ignorar, mínimo forzado, tamaño fijo; inspector "qué regla aplicó" con selector por clic), Diagnóstico, Importar AeroSpace, Desinstalar, búsqueda.
- Accesibilidad: Full Keyboard Access, tiles accesibles en la vista previa, glifos localizados, Liquid Glass con fallback a `NSVisualEffectView` y respeto a Reducir transparencia. Español e inglés.

## 10 · Primer arranque (7 pasos)

1. Accesibilidad (sin relanzar) + aviso de "elementos en segundo plano".
2. Conflictos: otro gestor en marcha → cerrar; **AeroSpace se importa** (con remapeo ES-ISO); avisos de Stage Manager, tiling nativo, "separate Spaces", > 1 Space **de escritorio** (los de pantalla completa no cuentan), "Agrupar por app".
3. Distribución de teclado y VoiceOver → preset (§7).
4. **Disposición de monitores** (§6.1): se muestra la disposición detectada, la esquina de ocultación por monitor y los avisos; con 1 monitor se resume en una línea.
5. **Defaults:** 5 escritorios "1…5" en el monitor principal; las ventanas se quedan en su monitor actual, todas en el escritorio 1 de ese monitor.
6. Vista previa de la primera activación + "Revertir a la disposición original".
7. Chuleta HUD + paso guiado ("prueba Ctrl-Opt-→" o su variante con VoiceOver).

El paso 4 se prueba en la fase 3 (multimonitor); el resto en la fase 2.

## 11 · Rendimiento (gates corregidos)

| Métrica | Objetivo |
|---|---|
| CPU en reposo | `powermetrics` 10 min: < 0,1 % y ≤ 20 despertares |
| Solver p99 (100 ventanas) | < 1 ms, determinista |
| Hotkey → primer `setFrame` | < 5 ms (**los hotkeys se saltan el lote**) |
| Aplicar 10 ventanas (**≤ 3 por pid, apps rápidas**) | p95 < 60 ms hasta el último marco observado = plan (las escrituras dentro de una app son en serie: 0,5–5 ms por llamada) |
| Veredicto I9 | ≤ settle + 300 ms (nunca < 250 ms de calma) |
| Monocle | p95 < 30 ms entre las 2 MRU; < 120 ms al traer una oculta en esquina |
| Memoria del motor | < 50 MB con 100 ventanas (agentes: 2,7 MB medidos) |
| Settings | Proceso aparte; delta 0 en el motor |

## 12 · Verificación

### Invariantes

I1 · I1b · I2 (modos de partición) · I3 · I4 · I5 · I5b · I6 · I7★ · I8 · I9★ · I10★ · I11★ · I12 · I13 · I14 · I15 · I16 · I17 · I18 · I19.

### Criterios pass/fail de cada spike

| Spike | Criterio |
|---|---|
| **S1** | Corpus committeado de 1.000 layouts semilla (10 apps nombradas: Terminal, iTerm, VS Code, Simulator, Ajustes, Xcode, Safari, Finder, Slack, Preview × 100) en el monitor del usuario. **PixelCheck** alcanza antes **100 % de exhaustividad en 60 huecos sintéticos** (1/2/4/8 px en bordes y costuras). Layouts donde PixelCheck ve ≥ 2×2 px fuera de la máscara mientras I9 pasa: **0**. De los layouts que el solver marca factibles (N reportado), ≥ 99 % pasan I9 en la primera calma; el resto termina en un estado terminal enumerado. Residuo ≤ q−1 por ventana cuantizada. Además: un binario **sin Screen Recording** obtiene Bounds/Layer/PID/Alpha. Fallbacks: A restricción dura → B auto-float → C lista de apps conocidas. |
| **S2** | Sobre la **matriz de disposiciones** (§6.1) que el usuario monte físicamente (mínimo: 1V, 2 monitores V+H en 4 posiciones relativas, 2V) y las restantes con `CGVirtualDisplay`: el modelo de clamp predice el marco observado ±1 pt en ≥ 99 % de 500 colocaciones por borde y disposición; k ≤ 10 pt; lista de esquinas seguras por disposición; decide en cuáles monocle puede ocultar sin encoger. Ambos modos de "separate Spaces". |
| **S3** | 100 agentes < 5 MB; un SIGSTOP nunca añade > 5 ms a otras apps; 0 falsos `unresponsive` en 1 h con Xcode indexando; **en 26 y en 15.2** (`isIsolatingCurrentContext` y `checkIsolated`). |
| **S4** | Atajos Option-only **entregados** 100/100 en 26 **y en 15.2** (volumen externo); si 15.2 falla, D5 sube a 15.3 o al primer 15.x que pase; el tap activo funciona solo con Accesibilidad; medir si un tap de escucha exige Input Monitoring. |
| **S5** | `CGVirtualDisplay` creado y retirado 100× sin fugas; `visibleFrame` coincide con el físico; **nunca como fuente de espejo** (tumba el WindowServer en 26). |
| **S6** | CST TOML sin pérdidas: 200/200 configs round-trip byte a byte (incluida la del usuario). |
| **S7** | Adoptar SLPS si el foco por API pública falla en > 2 % de 500 cambios; z-order de flotantes mantenido ≥ 95 % (muestras cada 100 ms, sesión guionizada de 10 min). |
| **S8** | Para cada evento (Dock cambia de pantalla, auto-ocultar, barra de menú) una fuente lo detecta en ≤ 500 ms, o se adopta sondeo de 1 s durante actividad. |
| **S9** | Dos monitores idénticos sin serial (emuladores EDID) conservan identidad en 20 reconexiones en orden aleatorio. |
| **S10** | `offSpace` detectado por la ventana de 1 s tras `activeSpaceDidChange` con 0 falsos "muerta" en 100 cambios de Space. |
| **S11** | **Nocturna en el Mac del usuario:** el cambio automático a la cuenta de laboratorio (sin contraseña, `CGSession -switchToUserID` a las 03:00) y la vuelta funcionan 20/20 noches sin intervención; la sesión del usuario queda intacta (0 ventanas movidas en su cuenta); el harness obtiene Accesibilidad y Screen Recording en la cuenta de laboratorio y los conserva tras rebuilds. |

Cada spike termina con un **ADR (go / no-go / fallback)**, script reproducible en `spikes/Sx/` y datos crudos committeados.

### Métodos, laboratorio, flakiness, DoD

- Propiedades: monitores **1080×2560 y 2560×1080 a escala 1 (el del usuario)**, 1440×2560, 800×600, 5120×1440, 3840×2160 a escala 1/2/fraccionaria. Model-based 1 M/noche. Fakes con clamp y fixture n.º 1.
- **`tessera doctor`:** inicializa `NSApplication` antes de leer `screensHaveSeparateSpaces` (verificado: `false` antes, `true` después); altura de barra = `frame.maxY − visibleFrame.maxY` (30 pt, no `NSStatusBar.thickness` = 22); registra el tipo de Space actual.
- **Permisos del harness (antes no presupuestados):** **Screen Recording** para PixelCheck (ScreenCaptureKit es la única vía: `CGWindowListCreateImage` no está en el SDK 15+; macOS re-pide el permiso periódicamente → S1 mide la cadencia en 26 y, si rompe la nocturna, se usa un clic HID); Accesibilidad para el harness (firma estable); Automation por app guionizada; posible Input Monitoring.
- **Laboratorio (D13): el Mac Studio del usuario.**
  - **Cuenta `tessera-lab`** separada, sin contraseña, con Accesibilidad y Screen Recording concedidos a mano una vez (persisten por la firma estable). La **nocturna** cambia a esa cuenta a las 03:00 por cambio rápido de usuario y vuelve al terminar (S11). La sesión del usuario nunca se toca: dogfooding = modo sombra + vistos buenos.
  - **Monitores:** los que el usuario conecte (hasta 5). El Gauntlet marca qué disposiciones de la matriz (§6.1) requieren montaje físico y cuáles se cubren con `CGVirtualDisplay`. El hot-plug (C04, C18) se hace **a mano** o con un switch DP si el usuario decide comprarlo; la rotación (C03) a mano.
  - **Volumen externo con macOS 15.2** para S3/S4 y la suite de 15.x antes de cada release.
  - Sin MDM: nada de PPPC. Screen Recording re-pide permiso periódicamente en 15+: S1 mide la cadencia y, si rompe la nocturna, se acepta un clic HID (emulador USB) o se limita PixelCheck a las ejecuciones supervisadas.
  - Sin FileVault en la cuenta de laboratorio no es necesario: FUS no lo requiere.
  - x86_64: CI alojada para Core/Config/fakes; una máquina Intel prestada para la suite de plataforma antes del release.
- **Flakiness y DoD:** producto = cualquier invariante (sin reintento); infra = solo antes del primer evento de Tessera; > 5 % infra = fallo; cuarentena incompatible con la DoD. **"5 noches" = las últimas 5 nocturnas programadas con 0 fallos de producto y ≤ 5 % infra; una noche sin ejecutar cuenta como fallida.** Cada challenge ha pasado 20 ejecuciones acumuladas y afirma todas las ★. C19 = 4 de 4 soaks semanales. Manuales fuera de la nocturna. **Visto bueno del usuario** = checklist firmado en `docs/signoff/phaseN.md`: 5 días laborables con ≥ 4 h de uso, 0 pulsaciones de "veo un hueco", 0 ventanas fuera de pantalla. **P0** = pérdida de datos, ventana fuera de pantalla, bloqueo de atajos o crash-loop.

### The Gauntlet

C01–C40 como v3.1, con estas correcciones de medibilidad: C23 "todas restauradas ≤ 1 s desde el arranque del motor y ≤ 7 s de reloj desde SIGKILL" (ThrottleInterval 5) · C33 "0 píxeles magenta en frames SCK a 60 fps durante los 500 ms tras cerrar" · C19 "footprint físico crece < 5 MB entre la hora 1 y la 8" · S7/z-order con denominador de muestras · C29 primer arranque "cada usuario termina el onboarding sin ayuda en ≤ 10 min con 0 ventanas perdidas" · paridad = `docs/parity.md` enumera los 41 comandos de `docs/aerospace-*.adoc`, cada uno con test de integración · importador "≥ 95 % de claves sin diff semántico en 20 configs públicas fijadas + la del usuario, 21/21 cargan". Etiquetas F/V/M.

**Nuevos por D12 (disposiciones):** **C41** (V+F) cada disposición de la matriz §6.1 → I7, I9, I14 y el perfil se reconoce 20/20 al reconectar · **C42** (F) cambio entre 3 disposiciones distintas ×20 con 30 ventanas → OSD correcto cada vez, 0 ventanas perdidas, escritorios vuelven a su hogar · **C43** (V) 200 disposiciones aleatorias generadas (tamaños, escalas, desalineaciones) → I7/I9/I14 en fakes · **C44** (F) VoiceOver anuncia los cambios de disposición con el texto de §6.1.

## 13 · Alcance y hoja de ruta

### Dimensionamiento (medido)

AeroSpace: **~21k LOC Swift** (AppBundle 10.970 en 135 archivos, Common 4.197, Cli 226, tests 5.594), ~3 años, un mantenedor principal, aún "Public Beta" y con su refactor del árbol (#1215) abierto. Sin GUI de ajustes, sin TOML sin pérdidas, sin journal, sin fakes, sin harness de píxeles. **Plan completo de Tessera: 51–76k LOC de producto + 20–30k de tests (3,5–5× AeroSpace).** Con un desarrollador + IA, **44 semanas tenía ~10 % de probabilidad; P50 ≈ 66 semanas**, cruzando WWDC 2027 y el lanzamiento de macOS 27. La IA duplica la velocidad del código puro (Core, Config, SwiftUI) pero no la de los experimentos AX/WindowServer, la puerta nocturna ni los vistos buenos, que van a reloj de pared.

### D11 · Plan completo, estimación honesta

El usuario ha optado por el programa completo. La estimación se mantiene tal y como salió del dimensionamiento: **57–80 semanas, P50 ≈ 66**, con estas reglas:
- Cada fase tiene DoD (§12) y ≥ 1 semana de estabilización.
- **Regla de corte:** si una fase supera 1,5× su estimación, se **re-secuencia** (lo que falte pasa a la fase siguiente o a una fase "cola" antes del release), nunca se relaja la DoD ni se elimina alcance sin decisión explícita del usuario.
- **Checkpoint de uso diario en la semana ~22** (fin de la fase 3): Tessera sustituye a AeroSpace en el Mac del usuario aunque falten paridad, GUI completa y Sparkle. No recorta alcance: valida el núcleo con uso real durante el resto del programa.
- **Cruce con macOS 27** (WWDC junio 2027): semana reservada en la fase 6 para la beta; el soporte de 27 se evalúa entonces.

### Hoja de ruta

| Fase | Sem. (P50) | Contenido | DoD |
|---|---|---|---|
| **0 · Spikes + prototipos** | 8 | S1–S11 con **prototipos desechables** de solver, reconciliador, auditor e I9 (S1 los necesita); `tessera doctor` → fixtures de **cada disposición** que el usuario monte; PixelCheck con máscara y corpus de 60 huecos sintéticos; harness + `DummyWindowApp`; cuenta `tessera-lab` y volumen 15.2; línea base de memoria; repo, CI (arm64 + x86_64), firma estable, `NOTICE` | ADR por spike; S1 según §12; S2 sobre la matriz de disposiciones |
| **0.5 · Modo sombra** | 3 | Auditor + área útil + I9 definitivos; observa junto a AeroSpace sin escribir; **PixelCheck cada 60 s durante ≥ 40 h de uso** + `tessera hole` por CLI (no hotkey: colisionaría con los 81 de AeroSpace) | Línea base de huecos de AeroSpace; precisión/exhaustividad del detector |
| **1 · Core** | 7 | Árbol, ppm, solver, 5 modos, overflow/underfill, aspecto, flotantes, undo, asignación, **perfiles de disposición**, HidePlanner, máquina de estados, reducer, I1–I19 en fakes | 1.000.000 casos semilla con 0 fallos; C43; solver p99 < 1 ms en el Mac Studio |
| **2 · Motor en un monitor + producto base** | 12 | Platform, reconciliación, I9, journal, agente, rescate, modo seguro, protocolo `handoff`, persistencia, escritorios, monocle, hotkeys + presets, tap de ratón (redimensión), CLI básica, barra de menú, bordes, onboarding (pasos 1–3, 5–7), importador con remapeo, diagnóstico, tabla de errores, Settings básicos (modo overlay), XPC | C01, C06, C08–C10, C14, C21, C23, C28, C29, C32 (sin anuncios), C33, C34, C37, C38a; primer arranque con 2 usuarios (uno ES-ISO) |
| **3 · Multimonitor y disposiciones** | 8 | Topología, identidad, rotación, perfiles y comunicación por disposición (§6.1), sueño/bloqueo/FUS/Spaces, pestañas, políticas macOS, Stage Manager, onboarding paso 4; nocturna operativa en `tessera-lab` | C02–C05, C07, C12, C18, C22, C24–C27, C30, C35, C36, C41, C42, C44 · **Checkpoint: el usuario sustituye AeroSpace** |
| **4 · Paridad y producto** | 8 | 41 comandos AeroSpace, modes + HUD, `on-window-detected`, ratón completo, master-stack/dwindle, escritorio maximizado por regla, scratchpad/sticky/marks, switcher, `subscribe`, `aerospace` opt-in, anuncios VoiceOver, SLPS si S7 lo decidió | Checklist de paridad; C11, C13, C15, C31, C32 completo, C40a–c |
| **5 · Settings completos** | 9 | CST sin pérdidas (S6), sincronización bidireccional, retirada del overlay, backups/undo, anti-bloqueo, GUI completa, reglas + inspector, importador GUI, uninstall, en, accesibilidad | C16, C17, C38b, C40d; importador 21/21; QA VoiceOver/FKA |
| **5.5 · Usabilidad** | 2 | 3 usuarios de AeroSpace (uno con vertical, uno ES-ISO); copy final | 0 P0 |
| **6 · Beta y release** | 9 | Soak C19 (4/4), corpus C20, C39, suite 15.2 y x86_64 (Intel prestado), gates en CI, notarización, Sparkle, cask `auto_updates`, SemVer/`config-version`, docs, migración, vuelta a AeroSpace, `tessera report`, semana de beta de macOS 27 | **2 semanas seguidas de uso diario con 0 huecos por I9 y 0 `tessera hole`** (se reinicia con cualquier hueco; tope 12 semanas y después decisión explícita); 100 ejecuciones limpias acumuladas |
| **Total** | **66** | | |

### Semanas 1–4 (salidas comprobables a diario)

- **Semana 1:** repo + targets vacíos + CI verde (arm64 + x86_64) + `NOTICE`; firma Developer ID (`codesign -dv` con team ID) y permiso TCC que sobrevive a un rebuild; cuenta `tessera-lab` creada con permisos concedidos; `tessera doctor` → `fixture-001.json` (disposición actual) validado; `DummyWindowApp` gobernable por IPC (tamaño, mín/máx, cuanto, auto-resize).
- **Semana 2:** el usuario conecta los monitores; `tessera doctor` → fixtures de cada disposición de la matriz que se pueda montar; PixelCheck v0 (SCK, fondo magenta, máscara) con la cadencia de re-petición de Screen Recording en un ADR; corpus de 60 huecos sintéticos al 100 %; **S2** sobre las disposiciones montadas, k medido, ADR sobre monocle y esquinas seguras por disposición.
- **Semana 3:** solver desechable + bucle de reconciliación; auditor e I9 prototipo; **S1 parcial** (10 apps × 20 layouts) en el vertical y en una disposición V+H.
- **Semana 4:** S3 (executor + SIGSTOP, en 26 y en el volumen 15.2); S4 (entrega de hotkeys en 26 y 15.2, permisos de taps); S8; **S1 completo** (1.000 layouts) como job nocturno en `tessera-lab` (S11 preliminar); línea base de memoria; lista de ADRs con go/no-go.
- Semanas 5–8: S5, S6 (prototipo del CST), S7, S9, S10, S11 completo.

## 14 · Registro de riesgos (owner: el usuario; fechas relativas al día 1)

| # | Riesgo | P | I | Mitigación real y fecha |
|---|---|---|---|---|
| 1 | Sobrepasar la estimación (P50 66 semanas) | 0,6 | Alto | Regla de re-secuenciación (§13); checkpoint de uso diario en la semana ~22; revisión de estimación al cierre de cada fase |
| 2 | La puerta de 5 noches no cierra por flakiness | 0,7 | Alto | Pilotar la puerta sobre la suite de Core en la semana 6 |
| 3 | Screen Recording re-pide permiso y rompe la nocturna | 0,7 | Alto | Medir cadencia en 26 en la semana 2; clic HID de respaldo o PixelCheck solo supervisado |
| 4 | La nocturna en el Mac del usuario interfiere con su trabajo o no arranca | 0,5 | Alto | S11 en la fase 0; cuenta separada; ventana 03:00–06:00; abortar y volver si el usuario está activo |
| 4b | El usuario no puede montar alguna disposición de la matriz | 0,5 | Medio | `CGVirtualDisplay` para las virtuales; las físicas pendientes se marcan y se cubren antes del release |
| 5 | Regresiones AX en 26.x / beta 27 | 0,6 | Medio-alto | OS del laboratorio fijado; seguir la beta 27 desde junio 2027 |
| 6 | Fragilidad del executor propio | 0,4 | Alto | S3 en la semana 4; fallback a dispatch queue en ADR |
| 7 | Sin esquina segura → minimizar | 0,4 | Medio | S2 decide en la semana 2 |
| 8 | Bus factor / agotamiento | 0,5 | Alto | ADRs y estado escrito semanal |
| 9 | Pérdida de TCC al re-firmar o actualizar | 0,2 | Alto | Team ID fijo; probar C39 a mano en la fase 2 |
| 10 | Una disposición real de un usuario no está en la matriz | 0,4 | Medio | C43 (200 aleatorias en fakes); `tessera report` incluye la disposición; perfiles se crean desde el más parecido |
| 11 | 15.2 o x86_64 sin hardware de prueba a tiempo | 0,4 | Medio | Volumen externo 15.2 en la semana 1; Intel prestado reservado para la fase 6 |

---

## Anexo A · Trazabilidad

**Rondas 1–3:** como v3.1 (producto P01–P23 y 9 gaps; plataforma B1–B3, M1–M12, m1–m6, N1–N10; QA F01–F27, N1–N12; ronda 3 must-fix 1–10).

**Ronda 4 (ingeniería), verificación en el Mac:** D5 `isIsolatingCurrentContext` primario · §2 trap de closures MainActor · §2 semántica de timeouts · §5 logout = `willPowerOff` + SIGTERM · §5 `kCGWindowIsOnscreen` ausente · §5 S1 verifica sin Screen Recording · D9 `kickstart`/`register`/`XPC_SERVICE_NAME`/`handoff` · §3 `Crashed=true`, `RunAtLoad`, `ExitTimeOut` · §4.3 `kAXSizeAttribute`, literal privado · D2 125 dumps · §12 monitores 1080×2560 · `doctor` `NSApplication`/altura de barra/tipo de Space · §6 `NSScreen.CGDirectDisplayID`, `DCPAVServiceProxy` · §0.1 estado real; Spaces tipo 4 excluidos; 72 atajos a remapear; `tessera hole` por CLI.

**Ronda 4, arquitectura (sondas compiladas):** §2 `passRetained`, sin run loop anidado, `@unchecked Sendable`, 27 KB/agente · §4.2 solver corregido (aspecto derivado del cruzado, sin re-clamp, restos mayores en el bucle, cuantos normalizados, absorbedor con holgura, max con gaps, flexible en cruzado = todas, cruzado vacío → autoFloated) · §3 ppm con restos mayores y suelo por llenado de agua · §4.4 marcos intermedios, retiro ≤ g, settle en la última, backoff de la restricción dura, `selfResizing` sin vecinos, presupuesto por escritorio, intención acotada · §4.4 calma por ventana, `unverified`, `calmStarvation` · §5 muerta ⇔ fuera de `optionAll`; `offSpace` por ventana temporal + S10; escondidas-al-cerrar retiradas; colgadas ocultas se quedan ocultas · §3/§8 barrido tras topología y al salir de Pausado · §8 formato del journal, WAL + checkpoint, conflictos · §7 XPC para Settings; títulos suprimidos en el socket · §11 gates corregidos; hotkeys sin lote · §12 criterios de S2–S10.

**Ronda 4, alcance:** §13 dimensionamiento y estimación honesta, hoja de ruta re-secuenciada (prototipos en S1, `tessera hole` sin hotkey, `handoff` en fase 2 y Sparkle en fase 6 con C39 probado a mano antes), §12 DoD medibles (16 redacciones), permisos del harness, §14 registro con P×I y fechas, semanas 1–4.

**Decisiones del usuario tras la ronda 4:** D11 plan completo (el corte MVP propuesto se descarta; queda el checkpoint de uso diario) · D12 cualquier disposición de monitores con perfiles y comunicación (§6.1, C41–C44, S2 sobre la matriz) · D13 laboratorio en el Mac Studio del usuario (cuenta `tessera-lab`, S11, volumen 15.2, monitores que conecte).

## Anexo B · Preguntas abiertas (no bloquean la fase 0)

- Nombre definitivo y ruta del repo (p. ej. `/Volumes/Desarrollo/projects/tessera`).
- Qué monitores puede conectar el usuario en la semana 2 (modelos y orientaciones) para fijar qué disposiciones de la matriz son físicas y cuáles virtuales.
- Si compra un switch DP programable para automatizar C04/C18 (opcional; sin él, manuales).
- Facts precargados para apps comunes.
