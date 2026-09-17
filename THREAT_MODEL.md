# Cotejo Fase 2 · Modelo de amenazas

Mercado de préstamo aislado sobre el oráculo de la fase 1, en Whitechain.

Este documento existe para que un revisor pueda juzgar el diseño sin leer el código, y sobre
todo para que sepa **qué ataques no cubre**. Un modelo de amenazas que solo lista victorias no
es un modelo de amenazas.

---

## 0. El ataque que define el diseño

El 30 de agosto de 2026, Tectonic —mayor protocolo de crédito de Cronos, 121,7 M en depósitos—
fue explotado por 75 M. El mecanismo: un colateral con factor del 20% y apenas 1,34 M de
liquidez, cuyo precio subió 100× en veinte minutos. Crypto.com detuvo la cadena entera. El
capital era compartido entre todos los mercados, así que **un colateral malo drenó el pozo
completo**.

Tres propiedades del incidente, y la respuesta de cada una:

| Propiedad de Tectonic | Respuesta en Cotejo |
|---|---|
| Pozo compartido: un colateral malo alcanza todo el capital | Mercados aislados por `Id`; un colateral solo daña sus mercados |
| Precio movible por una sola fuente | El router revierte por INV-2 antes de publicar (fase 1) |
| Deuda muy superior a la liquidez que la respalda | `maxTotalBorrow` atado a la profundidad observada |

---

## 1. Reglas de admisión

Se validan al crear el mercado y revierten. Ninguna es relajable por gobernanza.

| Regla | Qué exige | Por qué |
|---|---|---|
| **R1** | El `oracleAdapter` apunta a rutas de Cotejo con `minSources >= 3` | Un precio de dos fuentes no tiene mediana defendible |
| **R2** | Esas rutas tienen `>= 3` `operatorGroup` distintos | Un activo que no se puede valorar de forma independiente no puede ser colateral |
| **R3** | `lltv <= MAX_LLTV` (86%) | Margen mínimo para que una liquidación sea viable |
| **R4** | El `irm` está en lista blanca de implementaciones desplegadas | Acota el daño de una curva de interés arbitraria |
| **R5** | `LIF <= min(fórmula derivada, techo absoluto)` | Ver §2 |
| **R6** | El registro `assetId -> token` confirma que el adapter valora los tokens del mercado | Sin esto, R1 y R2 verifican una ruta que podría no ser la del colateral |
| **R7** | Toda ruta usada por un mercado cumple `sources.length >= minSources + 2` | Ver §4 |
| **R8** | El adapter congela la política de ruta al desplegarse; `price()` revierte si la ruta viva se debilita | Gobernanza puede endurecer, nunca relajar |

### R6 es append-only, por necesidad

El registro `assetId -> token` vive en el `PriceRouter`. **Una vez fijado un mapeo, no puede
cambiar.** Si gobernanza pudiese remapear `keccak256("WBT/USD")` a otro token, todos los
mercados creados bajo el mapeo anterior quedarían valorando un activo distinto del que
custodian, en silencio y sin que ninguna invariante saltase. Un registro mutable convierte R6
en decoración. Es append-only y sin función de borrado.

---

## 2. Derivación de R5 — el tope de incentivo

El incentivo de liquidación no es un parámetro de gusto: es la cantidad exacta de valor que un
atacante puede extraer si consigue mover el precio hasta el borde de lo que la ruta tolera sin
revertir.

En el límite de LLTV, la deuda es `lltv × valorColateral`. Una liquidación embolsa
`LIF × deuda` en colateral, luego la fracción de colateral incautada es:

```
fracciónIncautada = LIF × lltv
```

La ruta puede estar equivocada hasta `deviationCombined` sin revertir — esa es precisamente la
tolerancia que INV-2 concede. Para que la incautación no supere el colateral **real** ni en el
peor error tolerado:

```
LIF × lltv  ≤  1 − deviationCombined

LIF_max  =  (WAD − deviationCombined) × WAD / lltv
```

con `deviationCombined = devColRoute + devLoanRoute`, ambas en WAD.

Valores verificados numéricamente:

| Rutas | Combinada | LLTV | `LIF_max` | Bono |
|---|---|---|---|---|
| 100 + 100 bps | 200 bps | 86% | 1,139535 | **13,95%** |
| 200 + 200 bps | 400 bps | 86% | 1,116279 | **11,63%** |

### Dos límites que la fórmula no pone, y hacen falta igual

**La fórmula no protege al prestatario.** Es un techo de *seguridad*, no de *economía*. A
LLTV 50% con rutas de 100 bps produce `LIF_max = 1,96`, es decir un bono del **96%**: el
liquidador se lleva casi el doble de lo que repaga. Eso no extrae valor vía error de oráculo
—que es lo que R5 vigila— pero sí exprime al prestatario. Por eso el mercado aplica
`LIF <= min(fórmula, MAX_LIF_ABSOLUTE)`. El techo absoluto no es una estimación de riesgo de
oráculo; es una protección distinta para un problema distinto.

**La fórmula impone un techo implícito a la tolerancia de ruta.** Cuando
`deviationCombined >= WAD − lltv`, el `LIF_max` cae por debajo de `WAD`: el liquidador
embolsaría menos de lo que repaga y nadie liquidaría jamás. Con LLTV 86% eso ocurre a partir de
**1400 bps combinados**. Por encima de `WAD` la fórmula underflowea. La creación del mercado
rechaza ambos casos explícitamente, porque un mercado sin liquidación viable no es un mercado
conservador: es un mercado con deuda incobrable garantizada.

---

## 3. Modo degradado

Cuando el router de la fase 1 revierte —precio obsoleto, desviación excesiva, concentración de
operador, pausa— el mercado entra en modo degradado.

| Operación | Estado | Razón |
|---|---|---|
| `repay` | **PERMITIDO** | No requiere precio. Reducir deuda siempre es seguro |
| `supply` | **PERMITIDO** | Añadir liquidez no puede dañar a nadie |
| `supplyCollateral` | **PERMITIDO** | Mejora la salud de la posición |
| `withdrawCollateral` | **PERMITIDO solo si `borrowShares == 0`** | Sin deuda no hay comprobación de solvencia que hacer |
| `withdraw` (suministro) | **BLOQUEADO** | Ver abajo |
| `borrow` | **BLOQUEADO** | Requiere comprobación de solvencia |
| `liquidate` | **BLOQUEADO** | Ver abajo |

El interés **sigue acumulando** durante la degradación. Congelarlo premiaría a quien la
provoca. La mitigación del riesgo de degradación prolongada es R7, no detener el reloj.

### Por qué bloquear liquidaciones

Es la decisión más contraintuitiva del diseño y la que un revisor preguntará primero.

Liquidar con un precio manipulado **es** el mecanismo de extracción. En Tectonic el atacante no
rompió el motor de liquidaciones: lo usó. Infló el precio de un colateral ilíquido y dejó que
la maquinaria del protocolo le entregase 75 M de activos buenos a cambio de garantía inflada.
Las liquidaciones funcionaron perfectamente; ese fue el problema.

El intercambio explícito: **preferimos deuda incobrable temporal a una liquidación basada en
una mentira.** La deuda incobrable es acotada, socializada entre los suministradores de ese
mercado, y recuperable si el precio vuelve. Una liquidación ejecutada a un precio falso es
irreversible y transfiere el valor a quien fabricó la mentira.

### Por qué `withdraw` del suministro también se bloquea

Permitir retirar suministro durante la degradación abre la **ventaja del primero en salir**: los
suministradores informados retiran mientras el precio no es confiable, y la deuda incobrable
que aparezca después se concentra en quienes quedaron. La socialización de M3 solo es justa si
nadie puede correr antes de que se reconozca.

---

## 4. R7 — por qué cinco fuentes y no tres

Con `minSources = 3` sobre **exactamente** tres fuentes, la caída de un solo reporter produce
`Cotejo__InsufficientSources`, el adapter revierte, y el mercado entra en modo degradado. Como
el modo degradado bloquea liquidaciones, eso significa:

> **La caída de un reporter congela el control de solvencia del mercado entero.**

Es una dependencia de liveness 1-de-3 para la seguridad del protocolo, y convierte un incidente
operativo rutinario —un proceso que se cae, una API que rate-limitea— en una parada del
mecanismo que mantiene solvente al mercado. Peor: le da a un atacante bajo el agua un objetivo
barato. No necesita manipular un precio; le basta con tirar un reporter.

R7 exige `sources.length >= minSources + 2`. Con `minSources = 3` son **5 fuentes de 5 grupos
de operador distintos**, y hacen falta dos caídas simultáneas para degradar.

**Consecuencia para la fase 1:** el despliegue actual configura 3 grupos (`wgroup`, `binance`,
`kraken`) con `minSources = 3`. Esa configuración **no es apta para respaldar un mercado**.
Antes de la fase 2 hacen falta cinco `AttestationSource`, una por operador independiente.

---

## 5. Lo que este diseño NO cubre

La parte que importa.

### 5.1 `depthUsd` lo declaran las partes de las que nos defendemos

El tope de deuda se calcula sobre profundidades **auto-reportadas** en las atestaciones. No hay
ninguna comprobación on-chain de que esa liquidez exista. Un conjunto de reporters coludido
infla `depthUsd`, eleva `maxTotalBorrow`, y habilita exactamente el sobre-endeudamiento que el
tope existe para impedir.

Mitigaciones parciales, ninguna suficiente:
- R2 y R7 exigen que la colusión abarque varios operadores independientes.
- M1 tomaba el **mínimo**; ahora toma el **segundo-menor**, leído a través del router para que
  herede INV-2 e INV-5. El intercambio es exacto y **cuesta algo real**: con el mínimo bastaba un
  reporter honesto para acotar el tope, pero un solo reporter malicioso lo llevaba a cero y
  bloqueaba todos los préstamos de la ruta. Con el segundo-menor hacen falta dos mentirosos para
  inflarlo y dos para denegarlo. Ceder "basta uno honesto" solo es defendible porque A1.1 acota
  la pérdida sin consultar a ningún reporter. Los dos se despliegan juntos o ninguno.
- El clamp de crecimiento (2500 bps/hora) elimina la inflación instantánea justo antes de un
  préstamo grande.

Dos defensas añadidas después de escribir este documento:

- **A1.1 — techo absoluto (`MAX_ADAPTER_DEBT_USD`).** Inmutable, fijado antes del despliegue,
  aplicado por adapter. Es el **único mecanismo del diseño cuya garantía no depende de que
  ningún reporter sea honesto**: bajo colusión total convierte una pérdida ilimitada en una
  acotada. No impide el ataque; acota lo que vale.
- **A1.2 — realimentación por deuda incobrable.** Cuando una liquidación deja bad debt, el
  ancla de profundidad se recorta al 50%. La deuda incobrable es prueba on-chain de que la
  profundidad declarada no estaba ahí: un liquidador no pudo deshacer la posición contra el
  libro que supuestamente existía. Es la única comprobación del sistema sobre una afirmación
  de reporter que usa evidencia que los reporters no producen. Llega después del hecho.

Aun así, **un conjunto mayoritariamente coludido y paciente puede inflar el tope** hasta el
techo absoluto. La raíz no tiene solución dentro de este alcance: exigiría prueba de liquidez
on-chain, que en Whitechain testnet no existe porque no hay DEX. En mainnet, WhiteSwap
sobrevive la migración, y añadir una fuente TWAP a la ruta **no requiere cambiar ningún
contrato de la fase 2** — R8 solo revierte si la ruta se debilita, y añadir un operador la
fortalece.

### 5.2 Bloquear liquidaciones es un vector de griefing — ahora con salida acotada

Un prestatario bajo el agua se beneficia de la degradación. R7 encarece provocarla, pero no la
elimina. La salida es **A2, `liquidateDegraded`**: tras 72 h de degradación continua se abre
una liquidación pro-rata que **no consulta ningún precio vivo**.

Por qué no reabre el camino de extracción: no hay precio en la fórmula de incautación, así que
no hay nada que manipular. Con prima cero la incautación es exactamente proporcional, lo que
deja el ratio de colateralización **igual que estaba** — es aritméticamente neutra. Toda la
ventaja del liquidador es la prima: máximo 10%, alcanzada solo tras 72 h más una rampa de siete
días de fallo *continuo*, limitada a la mitad de la deuda, y exige adelantar tokens reales
contra una posición que por definición ya está bajo el agua.

La elegibilidad la decide el ancla de precio, que es el único lugar donde un precio almacenado
entra en el mercado, y obedece una regla comprobable con un `grep`:

> **INV-7'** — un precio almacenado solo puede *restringir* una acción. Ningún camino de código
> puede calcular una cantidad de tokens a partir de él.

Fijado en `testFuzz_A2_seizureIsIndependentOfPrice`, que varía el precio subyacente sobre 512
ejecuciones y exige que la incautación no cambie.

**Lo que NO hace:** no restaura la salud. Encoger proporcionalmente una posición bajo el agua la
deja bajo el agua. Es una válvula de liquidación ordenada, no una reparación de solvencia, y
fingir lo contrario sería deshonesto.

Un descuido corregido de paso: `RouteGovernor.setGuardian` era inmediato, justificado con "un
guardián solo puede pausar, luego concederlo no puede dañar". Eso valía cuando el router estaba
solo. Con la fase 2 es falso — pausar congela liquidaciones, que es un evento de solvencia. Así
que **conceder** el poder de pausa ahora espera 48 h (A6.3); revocarlo sigue siendo inmediato.

### 5.3 Colusión total del oráculo — acotada al alza, no a la baja

Si todos los grupos reportan el mismo precio falso, la desviación es cero y INV-2 nunca salta.
R2 y R7 compran independencia estructural, no honestidad.

**A3 cierra la dirección alcista.** El mercado guarda un ancla de precio con límite de velocidad
y revierte `borrow` y `withdrawCollateral` si el precio vivo sube más rápido que la banda (5%
instantáneo, +20%/hora, techo 50%). Compara contra lo que este mercado mismo vio hace un
momento, no contra lo que dicen los otros reporters — que es exactamente lo que un consenso
mentiroso no puede falsear. El clamp del ancla es la mitad que un revisor se salta y la que hace
que funcione: sin él, el cortacircuitos cae en un bloque (inflas el precio, llamas a cualquier
mutador permissionless para anclar la mentira, y pides prestado).

**La dirección bajista queda deliberadamente sin cubrir, y hay que decirlo claro.** Un
cortacircuitos sobre un precio que cae saltaría durante un crash genuino, degradaría el mercado,
y congelaría las liquidaciones justo cuando más importan: **fabricaría la deuda incobrable que
dice prevenir**. La única variante segura calcularía la incautación a partir de un precio
almacenado, violando INV-7'. Por eso `liquidate` **nunca** está sujeto a la banda — esa exención
es la propiedad que hace seguro todo el mecanismo, y está fijada en
`test_A3_liquidationIsNeverGatedByTheBand`.

Así que bajo colusión total la dirección deflacionaria **no se previene**. Queda acotada por
`MAX_ADAPTER_DEBT_USD` y por la pausa de guardián, y por nada más.

### 5.4 Ausencia de liquidadores

`maxTotalBorrow` supone que existen liquidadores dispuestos y capitalizados. Si nadie liquida,
el tope no salva nada: solo garantiza que la deuda *podría* deshacerse, no que se deshaga.

### 5.5 Captura de la lista blanca de IRM

**Corrección.** La versión anterior de esta sección afirmaba que el daño máximo era un tipo de
interés absurdo. Era falso. `IIrm.borrowRate` no es `view` y se llama desde los siete
mutadores, así que un IRM que revierte —o un proxy repuntado más tarde a uno que revierte, o
uno que simplemente quema todo el gas— **congelaba el mercado entero de forma permanente,
`repay` y `liquidate` incluidos, con los fondos dentro**. Y como `irm` forma parte del `Id`,
quitarlo de la lista blanca no rescataba un mercado ya creado: R4 es una comprobación de
creación, nada más. Congelar es peor que un 800% de interés.

Cerrado con tres capas:

- **A5.1.** La llamada va con `try/catch` y `IRM_GAS_LIMIT = 150 000`, el mismo patrón que
  `PriceRouter._readSource` aplica a las fuentes y por la misma razón: sin tope de gas, la
  regla 63/64 deja al llamante sin poder terminar y el `try/catch` pasa a ser el vector de
  denegación en vez de la protección. Un modelo que falla significa 0% de interés en ese
  intervalo, que es recuperable.
- **A5.2.** `ReentrancyGuard` en todos los mutadores. Un IRM de la lista blanca tenía un punto
  de reentrada dentro de `borrow` y `liquidate`, y lo único que lo impedía era confiar en la
  lista blanca — precisamente lo que esta amenaza asume comprometido.
- Queda pendiente el timelock sobre la lista blanca (A5.3). Compra poco por sí solo: R4 es de
  creación, así que revocar no afecta a mercados vivos.

### 5.6 MEV y competencia por liquidaciones

Sandwiching de liquidaciones, prioridad de gas, y captura del incentivo por buscadores no se
abordan. El close factor del 50% limita el tamaño por operación, no quién la captura.

### 5.7 Tokens no estándar

M6 valida por delta de balance en toda entrada, así que fee-on-transfer y rebasing **fallan en
el primer uso** en vez de corromper la contabilidad en silencio. Eso los detecta; no los
soporta. Un token con rebase positivo deja fondos huérfanos en el contrato.

### 5.8 Riesgo de la migración L1 → L2

Al migrar, el estado se conserva pero el chain ID cambia. Dos consecuencias:
- Las atestaciones EIP-712 firmadas antes de la migración dejan de validar. Es correcto, pero
  la flota de reporters debe reconfigurarse el mismo día.
- El chain ID de L2 Mainnet **aún no está publicado**, así que no puede fijarse por adelantado.

M7 elimina el riesgo relacionado: no se usa `block.number` en ningún cálculo temporal, porque
bloques de 1 s y un cambio de cadena convierten cualquier lógica por número de bloque en una
bomba de relojería.

### 5.9 Riesgo de gobernanza sobre la ruta

R8 impide que una ruta se debilite bajo un mercado vivo. Gobernanza sigue pudiendo **pausar** el
activo, lo que degrada el mercado y congela liquidaciones.

**Un mecanismo cubre las dos amenazas.** Una pausa de guardián y una caída de reporters son
indistinguibles en el adapter: ambas hacen revertir `price()`, ambas arrancan el mismo reloj, y
ambas abren `liquidateDegraded` tras 72 h. Fijado en
`test_A2_guardianPauseAlsoOpensTheWindDown`. Además, conceder el poder de pausa ahora espera 48 h
(A6.3), así que un owner comprometido no puede fabricarse un guardián en el mismo bloque.

### 5.10 Lo explícitamente fuera de alcance en v1

Flash loans, colateral cruzado, token de gobernanza, y cualquier función que permita cambiar el
`lltv` de un mercado existente. Esto último no es una omisión: escribirla reintroduciría el
problema que todo el diseño evita.

---

## 6. Invariantes verificadas en tests

| Invariante | Test |
|---|---|
| La suma de deuda de prestatarios nunca supera el total prestado | `invariant_borrowSharesNeverExceedTotal` |
| Ningún mercado toca el colateral de otro | `invariant_marketsNeverShareCollateral` |
| `totalBorrow` nunca supera `maxTotalBorrow` tras una operación exitosa | `invariant_borrowNeverExceedsDepthCap` |
| El redondeo siempre favorece al protocolo | `testFuzz_roundingFavoursProtocol` |
| R2 rechaza colateral con oráculo concentrado | `test_R2_rejectsCollateralWithConcentratedOracle` |
| El ataque de Tectonic no funciona | `test_TectonicReplay` |
| Una caída de profundidad bloquea préstamos, no habilita liquidaciones | `test_DepthCapBlocksBorrowNotLiquidation` |
