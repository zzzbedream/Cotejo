# Cotejo

Oráculo agregador de precios para **Whitechain Sepolia** (OP Stack L2, chain ID `1874`, gas token WBT).

Cotejo es seguro porque se niega a responder, no porque responda bien. Ante cualquier duda
revierte con un error tipado. Un consumidor que revierte es un consumidor vivo.

Expone `AggregatorV3Interface` con la firma exacta de Chainlink, de modo que cualquier
protocolo ya integrado puede apuntar a Cotejo sin cambiar una línea.

> El NatSpec de los contratos está en inglés, por convención de Solidity. Este README está en
> español; dilo y lo traduzco.

---

## Por qué existe

Whitechain no tiene ningún oráculo desplegado. Verificado contra la documentación oficial:
el índice (`llms.txt`) no contiene ninguna página de oráculos, y las seis apariciones de
"oracle" en la documentación completa son infraestructura de OP Stack, no feeds de precio:

| Aparición | Qué es |
|---|---|
| `GasPriceOracle` (`0x420…000F`) | Predeploy de tarifa de datos L1 |
| `l2OutputOracle` | Mencionado explícitamente como **no aplicable** (Whitechain usa fault proofs) |
| `preimageOracleChallengePeriod` | Parámetro de dispute game |
| "no gas-oracle action" | Nota sobre la API Etherscan-compatible |

No hay Chainlink, ni Pyth, ni RedStone. Tampoco hay stablecoin nativa (el gas token es WBT) y
los swaps están documentados como *"not available on any testnet"*. Por tanto **el precio
tiene que entrar desde fuera, firmado**, y el contrato asume que quien firma puede mentir o
estar comprometido.

### Parámetros de red verificados

Contra `/learn/network/reference`:

| Parámetro | Valor |
|---|---|
| Chain ID | `1874` (hex `0x752`), **Live** |
| L1 settlement | Ethereum Sepolia (`11155111`) |
| Block time | **1 s** |
| Min base fee | 5 gwei |
| Gas token | WBT, 18 decimales |
| RPC | `https://rpc.testnet.whitechain.io` |
| Explorer | `https://explorer.testnet.whitechain.io` |

Mainnet aún no está viva; su chain ID se publica antes del lanzamiento.

---

## Flujo del precio

```
  Reporters off-chain (claves registradas, un operatorGroup por fuente)
        │
        │  PriceAttestation{asset, price, decimals, observedAt, depthUsd, sourceId}
        │  firmada EIP-712  ──  submit() es permissionless: firma la autoriza, no el caller
        ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │ AttestationSource            ChainlinkCompatSource      TwapSource  │
  │ · rechaza observedAt futuro  · envuelve un feed          · v1: SIEMPRE│
  │ · rechaza repetidas          · exige answer > 0            REVIERTE  │
  │ · exige avance estricto      · exige answeredInRound     · supportsAsset
  │   en observedAt                >= roundId                  == false  │
  │ · exige depthUsd mínimo                                             │
  └─────────────────────────────────────────────────────────────────────┘
        │  IPriceSource.latestPrice(asset) → (price, decimals, observedAt, group)
        │  TODO view (D3). Cap de 200k gas por fuente.
        ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │ PriceRouter.latestPrice(asset)                                      │
  │                                                                     │
  │   0. ¿pausado?              ──► Cotejo__Paused              (INV-6) │
  │   1. lee cada fuente                                                │
  │        · revierte           ──► se descarta, no es fatal            │
  │        · observedAt futuro  ──► se descarta                         │
  │        · precio 0           ──► se descarta                         │
  │        · STALE              ──► Cotejo__StalePrice          (INV-3) │
  │        · ok                 ──► normaliza a 18 decimales            │
  │   2. |fresh| < minSources   ──► Cotejo__InsufficientSources (INV-1) │
  │   3. concentración operador ──► Cotejo__OperatorConcentration(INV-5)│
  │   4. insertion sort (n<=15, D4)                                     │
  │   5. (max-min)*1e4/mediana  ──► Cotejo__DeviationExceeded   (INV-2) │
  │   6. devuelve (mediana, 18, observedAt MÁS ANTIGUO del conjunto)    │
  └─────────────────────────────────────────────────────────────────────┘
        │
        ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │ CotejoAggregatorAdapter  ·  AggregatorV3Interface exacta             │
  │   latestRoundData() → reescala a los decimales del consumidor       │
  │                       roundId derivado de observedAt (monótono)     │
  │                       revierte si redondearía a 0 o excede int256   │
  │   getRoundData()    → SIEMPRE revierte: no hay histórico que fingir │
  └─────────────────────────────────────────────────────────────────────┘
        │
        ▼
   Protocolo consumidor (sin cambios de código)


  Camino administrativo — nunca toca un precio (INV-7)

   RouteGovernor ──48 h──► PriceRouter.commitRoute()      (INV-4)
   RouteGovernor ──48 h──► PriceRouter.unpause()          (INV-6)
   Guardián      ──ya───► PriceRouter.pause()             (INV-6)
```

---

## Las siete invariantes

| ID | Invariante | Test que la prueba |
|---|---|---|
| **INV-1** | `latestPrice` revierte si las fuentes frescas son menos que `minSources` | `test_INV1_revertsBelowMinSources`<br>`test_INV1_passesAtExactlyMinSources`<br>`test_INV1_revertingSourceIsDroppedNotFatal`<br>`test_INV1_gasBombSourceIsContainedAndDropped` |
| **INV-2** | Revierte si la desviación del conjunto fresco supera `maxDeviationBps` | `test_INV2_revertsWhenDeviationExceeded`<br>`test_INV2_deviationIsMeasuredAgainstMedianNotMin`<br>`test_INV2_passesAtExactlyMaxDeviation` |
| **INV-3** | Revierte si `block.timestamp − observedAt > maxStalenessSeconds` para **cualquier** fuente del conjunto | `test_INV3_revertsOnStaleSource`<br>`test_INV3_oneStaleSourceRevertsEvenWithQuorumOfFreshOnes`<br>`test_INV3_passesAtExactlyMaxStaleness`<br>`test_INV3_reportsOldestObservationInTheSet` |
| **INV-4** | Un cambio de ruta surte efecto solo tras `ROUTE_TIMELOCK = 48 h`, y la ruta pendiente es legible públicamente durante toda la espera | `test_INV4_routeChangeRequiresFullTimelock`<br>`test_INV4_pendingRouteIsPubliclyReadableForTheWholeWait`<br>`test_INV4_routeIsUnchangedWhileProposalIsPending` |
| **INV-5** | Independencia de operador: nunca más de `maxSourcesPerOperatorGroup` (default 1) por grupo, validado **al proponer Y al leer** | `test_INV5_rejectsTwoSourcesFromSameOperator`<br>`test_INV5_revertsAtReadWhenGroupChangesAfterCommit`<br>`test_INV5_honoursMaxSourcesPerOperatorGroupAboveOne`<br>`test_CircularPricing` |
| **INV-6** | La pausa es unidireccional hacia la seguridad: pausar es inmediato y de guardián; despausar pasa por el timelock completo | `test_INV6_guardianPausesImmediately`<br>`test_INV6_unpauseRequiresFullTimelock`<br>`test_INV6_guardianCannotUnpause`<br>`test_INV6_nonGuardianCannotPause`<br>`test_INV6_pauseSurvivesRepeatedGuardianCalls` |
| **INV-7** | Ningún rol administrativo puede escribir un precio. No existe esa función | `test_INV7_routerExposesNoPriceWritingFunction`<br>`test_INV7_governorCannotMovePriceWithoutSources` |

`test_INV7_routerExposesNoPriceWritingFunction` escanea el bytecode desplegado buscando nueve
selectores de escritura de precio. Es estructural a propósito: falla si alguien añade un
setter en el futuro, se llame como se llame.

### Escenarios

| Test | Qué reproduce |
|---|---|
| `test_TectonicScenario` | Una fuente ×100 en 20 min mientras dos permanecen estables. El router deja de responder durante la rampa; al final da exactamente `Cotejo__DeviationExceeded(990_000 bps, 500)` |
| `test_TectonicScenario_downwardRunawayIsAlsoRefused` | El caso espejo a la baja, que es el que dispara liquidaciones |
| `test_CircularPricing` | Tres fuentes con el mismo `operatorGroup`. Revierte **al proponer**, nunca entra en la cola |
| `test_TwapDisabled_cannotBeCommittedIntoARoute` | `TwapSource` no puede activarse por configuración, solo escribiendo la implementación |

---

## Decisiones de diseño

### D1 — La desviación se mide contra la mediana

```
(max − min) × 10 000 / mediana  ≤  maxDeviationBps
```

**Esto no es simétrico.** Para el mismo spread absoluto, la cifra depende de qué lado esté la
mayoría:

| Conjunto | Mediana | Spread | Desviación |
|---|---|---|---|
| `[100, 100, 200]` — mayoría baja, outlier **alto** | 100 | 100 | **10 000 bps** |
| `[100, 200, 200]` — mayoría alta, outlier **bajo** | 200 | 100 | **5 000 bps** |

Un outlier a la baja bajo una mayoría cara se juzga con la mitad de severidad, porque divide
por una mediana mayor. Esa es la dirección que dispara liquidaciones, así que
`maxDeviationBps` **protege de forma asimétrica** y una ruta debe calibrarse pensando en el
caso descendente. Fijado como propiedad en `testFuzz_deviationBps_medianBaseIsAsymmetric`.

`(max − min) × 10 000` desborda por encima de ~1.15e73 y revierte. Es intencionado: un número
así no es un precio, y fallar cerrado es la respuesta correcta.

### D2 — `maxStalenessSeconds ≥ 2 × reporterHeartbeatSeconds`

Validado al configurar la ruta. El despliegue usa heartbeat de 900 s y staleness de 1800 s: el
mínimo exacto que D2 permite. Eso es precisamente lo que la regla del doble compra — la
comprobación es `edad > maxStaleness`, estricta, así que la ventana **tolera un latido perdido
entero y falla al segundo consecutivo**. El heartbeat lo fija el presupuesto del faucet (ver
`DEPLOYMENT.md` §2), no la preferencia; la ventana de frescura es un parámetro de seguridad y no
se ensancha para acomodar un keeper poco fiable. Por debajo del doble, la operación normal dispara reverts aleatorios y nadie
entiende por qué. `reporterHeartbeatSeconds` vive en la `Route`, no en la fuente: leerlo de la
fuente dejaría que una fuente mentirosa declarase un heartbeat diminuto para pasar el check.

### D3 — Todo el camino de lectura es `view`

Fuente → router → adaptador, sin excepción, para que `latestRoundData()` sea `view`, que es
como lo llaman todos los consumidores. Una fuente que necesite escribir estado para responder
no puede ser una fuente. Para un modelo pull estilo RedStone, la extracción desde `msg.data`
funciona en contexto `view`; está documentado en `IPriceSource`.

### D4 — `MAX_SOURCES_PER_ROUTE = 15`, insertion sort en memoria

O(n²) a propósito: con n ≤ 15 gana a cualquier alternativa en gas y es auditable de un
vistazo. Acota el coste de la lectura, que es lo que importa cuando un liquidador llama bajo
presión.

### Otras cinco, cerradas en revisión

| Decisión | Resolución |
|---|---|
| Fuente que revierte | Se descarta y cuenta como no fresca; `minSources` decide. Cap de 200 000 gas por fuente contra griefing 63/64 |
| Mediana con N par | Promedio de los dos centrales, redondeo abajo, calculado como `lo + (hi−lo)/2` para no desbordar |
| `observedAt` devuelto | El **más antiguo** del conjunto, no el más nuevo: el consumidor mide contra el eslabón más débil |
| `getRoundData` | Revierte con `Cotejo__HistoricalDataUnavailable`. No hay rondas; inventar una violaría fail-closed |
| Precisión en el adaptador | Revierte si el reescalado redondearía a cero, en vez de devolver 0 |

Nota: **una fuente que revierte se descarta, pero una fuente que responde con dato viejo
revierte toda la lectura.** No es una contradicción. Una fuente ausente es una fuente ausente;
una fuente que contesta con datos rancios es señal de que algo va mal aguas arriba.

---

## Dependencias

**OpenZeppelin 5.1.0**, no solmate. Razones, por orden:

1. `ECDSA` rechaza maleabilidad (`s > n/2`); solmate no cubre ese caso igual.
2. `EIP712` cachea el domain separator con protección ante fork, relevante en una L2 cuyo
   chain ID de mainnet aún no existe.
3. `Ownable2Step` evita perder el control por un typo en una transferencia.
4. La propia documentación de Whitechain demuestra OpenZeppelin verificable en este Blockscout
   (su despliegue de referencia usa `@openzeppelin/contracts@5.6.1`).

**Por qué 5.1.0 y no 5.6.1:** OZ 5.6.1 usa `mcopy` en `Bytes.sol`, que `Math.sol` importa, y
`mcopy` es un opcode de Cancun. Con `evm_version = "shanghai"` el build falla. 5.1.0 es la
última que no lo usa, así que conserva el target shanghai sin renunciar a una OZ moderna.

### Sobre `evm_version = "shanghai"`

La cadena **sí soporta Cancun**: Holocene está activo desde génesis y el despliegue de
referencia de la documentación verifica con EVM `cancun` y solc 0.8.28. Mantenemos `shanghai`
porque Cotejo no usa transient storage, el bytecode shanghai corre sin cambios en una cadena
cancun, y el target más antiguo mantiene los artefactos portables a cualquier cadena OP Stack
que aún no haya activado Ecotone. Es una elección, no un límite.

`v0.8.24+commit.e11b9ed9` está confirmado en la lista de compiladores del explorer
(`GET /api/v2/smart-contracts/verification/config`), así que el contrato es verificable.

---

## Cobertura

269 tests en 24 suites. `forge coverage --no-match-coverage "(test/|script/)"`, ambas capas:

```
╭------------------------------------------+-------------------+--------------------+------------------+------------------╮
| File                                     | % Lines           | % Statements       | % Branches       | % Funcs          |
+=========================================================================================================================+
| src/PriceRouter.sol                      | 100.00% (148/148) | 99.44% (177/178)   | 97.44% (38/39)   | 100.00% (19/19)  |
|------------------------------------------+-------------------+--------------------+------------------+------------------|
| src/RouteGovernor.sol                    | 100.00% (79/79)   | 100.00% (78/78)    | 100.00% (14/14)  | 100.00% (17/17)  |
|------------------------------------------+-------------------+--------------------+------------------+------------------|
| src/adapters/CotejoAggregatorAdapter.sol | 100.00% (25/25)   | 100.00% (23/23)    | 100.00% (3/3)    | 100.00% (6/6)    |
|------------------------------------------+-------------------+--------------------+------------------+------------------|
| src/libraries/AggregationLib.sol         | 100.00% (35/35)   | 100.00% (50/50)    | 100.00% (8/8)    | 100.00% (4/4)    |
|------------------------------------------+-------------------+--------------------+------------------+------------------|
| src/market/AdaptiveCurveIrm.sol          | 92.50% (37/40)    | 94.12% (48/51)     | 100.00% (11/11)  | 83.33% (5/6)     |
|------------------------------------------+-------------------+--------------------+------------------+------------------|
| src/market/CotejoMarket.sol              | 99.56% (448/450)  | 99.25% (527/531)   | 96.70% (88/91)   | 98.25% (56/57)   |
|------------------------------------------+-------------------+--------------------+------------------+------------------|
| src/market/CotejoOracleAdapter.sol       | 98.65% (73/74)    | 96.77% (90/93)     | 90.00% (9/10)    | 100.00% (16/16)  |
|------------------------------------------+-------------------+--------------------+------------------+------------------|
| src/market/libraries/MathLib.sol         | 100.00% (19/19)   | 100.00% (23/23)    | 100.00% (0/0)    | 100.00% (8/8)    |
|------------------------------------------+-------------------+--------------------+------------------+------------------|
| src/market/libraries/SharesMathLib.sol   | 100.00% (8/8)     | 100.00% (8/8)      | 100.00% (0/0)    | 100.00% (4/4)    |
|------------------------------------------+-------------------+--------------------+------------------+------------------|
| src/sources/AttestationSource.sol        | 100.00% (73/73)   | 100.00% (76/76)    | 100.00% (18/18)  | 100.00% (17/17)  |
|------------------------------------------+-------------------+--------------------+------------------+------------------|
| src/sources/ChainlinkCompatSource.sol    | 100.00% (30/30)   | 100.00% (35/35)    | 100.00% (7/7)    | 100.00% (7/7)    |
|------------------------------------------+-------------------+--------------------+------------------+------------------|
| src/sources/TwapSource.sol               | 72.73% (8/11)     | 66.67% (4/6)       | 100.00% (0/0)    | 80.00% (4/5)     |
|------------------------------------------+-------------------+--------------------+------------------+------------------|
| Total                                    | 99.09% (983/992)  | 98.87% (1139/1152) | 97.51% (196/201) | 98.19% (163/166) |
╰------------------------------------------+-------------------+--------------------+------------------+------------------╯
```

**El número es el 97,51 % de ramas.** Se cita la cobertura de ramas y no la de líneas
(99,09 %) ni la de funciones (98,19 %) porque es la difícil de mover; citar cualquiera de las
otras a solas sería selectivo.

Este README mostró durante un tiempo un 100 % de ramas: era la corrida de solo la capa de
oráculo, tomada antes de que existiera el mercado. Era cierta sobre lo que medía y falsa sobre
este repositorio — la cifra real en ese momento era 73,63 %, con `CotejoMarket.sol`, el
contrato que custodia fondos, en 59,34 %.

Las cinco ramas que faltan **no son "todavía no"**: cada una se rastreó hasta su llamador y
ninguna es alcanzable. Ninguna sostiene nada; las cinco son defensa en profundidad detrás de
una comprobación que dispara antes. Están enumeradas una por una, con el motivo, en
[`coverage.txt`](coverage.txt). Una rama inalcanzable documentada dice más que un porcentaje
que la promedia.

El test de invariante de Foundry corre 256 secuencias × 64 llamadas por run sobre seis
acciones del handler (reportar, reportar con retraso, reportar con otra escala, caídas,
reasignación de operador, paso del tiempo) y recomputa el resultado esperado directamente
desde las fuentes, sin pasar por el router, para que la comparación sea independiente.

---

## Despliegue y verificación pública

**Fase 1 en cadena desde el 18 de septiembre de 2026**, en Whitechain Sepolia (chain id 1874).
Ocho contratos desplegados y verificados en Blockscout:

| | |
|---|---|
| `PriceRouter` | [`0xB4f9C215…0Fd096`](https://explorer.testnet.whitechain.io/address/0xB4f9C2151B73eDEa730A72e9642C971d803Fd096) |
| `RouteGovernor` | [`0x116a41d0…5341D`](https://explorer.testnet.whitechain.io/address/0x116a41d02bF43f7c15D9DB8EC3e0fDccAE55341D) |
| `AttestationSource` × 5 | `cotejo-keeper-1..5`, una por grupo de operador |
| `CotejoAggregatorAdapter` WBT/USD | [`0xc7624150…faE16`](https://explorer.testnet.whitechain.io/address/0xc7624150c28bF26cdF920A0715a7c0ba614faE16) |

La lista completa, con lo que se comprobó leyendo la cadena en vez del log del despliegue, está
en [DEPLOYMENT.md §1-bis](DEPLOYMENT.md).

**Hoy el oráculo se niega a dar precio, y eso es lo correcto.** `latestRoundData()` revierte con
`Cotejo__RouteNotConfigured`: los contratos existen, pero ninguna ruta está instalada todavía.
Servirá cuando pase el timelock de 48 h. Un oráculo que devolviera algo en este estado sería el
problema, no el progreso.

**El mercado de préstamo no está desplegado** y es deliberado: sin rutas instaladas no satisface
sus propias reglas de admisión, y la regla no se debilita para que quepa.

El guion completo de despliegue, los comandos exactos de verificación en Blockscout, el panel de
verificación y el guion de la prueba en vivo están en [DEPLOYMENT.md](DEPLOYMENT.md).

| Entregable | Dónde |
|---|---|
| Scripts de despliegue reanudables | [script/01_Deploy.s.sol](script/01_Deploy.s.sol), [02_Configure](script/02_Configure.s.sol), [03_ExecuteRoutes](script/03_ExecuteRoutes.s.sol) |
| Direcciones desplegadas | [deployments/1874.json](deployments/1874.json) |
| Panel de verificación (sin build, sin servidor) | [panel/index.html](panel/index.html) |
| Prueba adversarial en vivo | [script/LiveTest.s.sol](script/LiveTest.s.sol), ensayada en [LiveDemo.t.sol](test/scenarios/LiveDemo.t.sol) |

---

## Uso

```bash
forge build
forge test
forge coverage

# Barrido profundo antes de una auditoría: 10 000 runs de fuzz, 1 024 de invariante
FOUNDRY_PROFILE=deep forge test
```

### Despliegue en Whitechain Sepolia

Los contratos se referencian entre sí, así que el orden importa:

1. `PriceRouter(owner)`
2. `RouteGovernor(router, owner)`
3. `router.setGovernor(governor)` — una sola vez; después el owner pierde todo poder sobre routing, pausa y precios
4. `governor.setGuardian(guardian, true)`
5. Desplegar las fuentes, una `AttestationSource` por operador
6. `governor.proposeRoute(asset, route)` → esperar 48 h → `executeRoute(asset)`
7. `CotejoAggregatorAdapter(router, asset, decimals, description)`

El despliegue requiere TTY para la contraseña del keystore, así que ejecútalo tú:

```bash
forge create src/PriceRouter.sol:PriceRouter \
  --rpc-url https://rpc.testnet.whitechain.io \
  --account <account-name> \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url https://explorer.testnet.whitechain.io/api/ \
  --constructor-args <owner-address>
```

`--broadcast` es obligatorio: sin él `forge create` solo simula e imprime algo que parece un
resultado real. `--constructor-args` debe ir **el último**, porque es variádico y se traga
todos los tokens que le sigan.

Para multi-fichero, si `--verify` falla, usa el método `standard-input` de Blockscout.

---

## Lo que Cotejo no hace

- **No implementa TWAP.** `TwapSource` revierte siempre y `supportsAsset` devuelve `false`, así
  que no puede activarse por configuración. Existe un contrato etiquetado `UniswapV3Pool` en
  Whitechain Sepolia (`0x6e057133CFa4a9Ec70c77aaFe29751460FE16307`), pero sin factory
  documentada, sin direcciones de pool publicadas y sin swaps habilitados en testnet, un TWAP
  sobre él es un número que un atacante fija por el coste de mover un pool fino. Con bloques
  de 1 s, una ventana de 30 min son 1 800 bloques de una posición barata, no el disuasorio que
  es en una cadena de 12 s.
- **No es actualizable.** Contratos inmutables en v1; la migración se hace cambiando la ruta.
- **No emite ningún token** ni tiene gobernanza tokenizada.
- **No incluye el servicio off-chain** que firma las atestaciones.
- **No está optimizado para gas** más allá de lo que exige el cap de 15 fuentes.
- **No soporta reporters que sean contratos** (EIP-1271). `ECDSA.recover` deriva el firmante de
  la firma, y el struct `PriceAttestation` acordado no lleva una dirección de reporter que
  permitiese validar contra un contrato.

## Riesgos conocidos

| Riesgo | Alcance | Mitigación |
|---|---|---|
| Asimetría de D1 | `maxDeviationBps` es más permisivo con outliers a la baja | Calibrar la ruta pensando en el caso descendente |
| El owner del router puede quitar todos los guardianes | Pérdida de liveness, no de seguridad: no puede producir un precio ni despausar sin las 48 h | Owner en multisig |
| El owner de una fuente controla su `operatorGroup` | Podría declarar independencia falsa | INV-5 se revalida en cada lectura y en cada commit |
| `getRoundData` revierte | Rompe consumidores que recorran histórico | Deliberado; fingir un histórico sería peor |
