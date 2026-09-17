# Cotejo · Despliegue en Whitechain Sepolia

Guion completo para desplegar, verificar y demostrar Cotejo en testnet, y para que un tercero
compruebe que funciona sin confiar en nosotros.

---

## 1. Parámetros de red confirmados

Verificados contra `docs.whitechain.io/learn/network/reference` **y** contra el propio RPC, no
asumidos. Ninguno difiere de lo esperado.

| Parámetro | Valor | Cómo se confirmó |
|---|---|---|
| Chain ID | `1874` (hex `0x752`) | `eth_chainId` → `0x752` |
| RPC | `https://rpc.testnet.whitechain.io` | responde |
| Explorer | `https://explorer.testnet.whitechain.io` | Blockscout |
| Gas token | WBT, 18 decimales | referencia de red |
| Base fee mínima | 5 gwei | `eth_gasPrice` → `0x12a153440` = 5 000 000 000 wei |
| Block time | 1 s | referencia de red |
| Multicall3 | `0xcA11bde05977b3631167028862bE2a173976CA11` | `eth_getCode` devuelve bytecode, y está documentado |
| Faucet | **0,5 WBT / 24 h**, tier Standard | ventana rodante; límites por wallet, IP y cuenta GitHub |

> **Trampa de tooling.** `viem/chains` exporta `whitechainSepolia` (**1874**) y también
> `whitechainTestnet` (**2625**), que es *otra red*. Importar el segundo firma contra la
> cadena equivocada sin error visible. Tanto los scripts como el panel verifican el chain ID
> contra el RPC antes de hacer nada.

---

## 2. Presupuesto

Medido con `forge script` simulando contra el RPC real, no estimado a ojo.

| Contrato | Gas | WBT @ 5 gwei |
|---|---:|---:|
| AttestationSource × 3 | 4 900 750 | 0,024504 |
| PriceRouter | 2 162 238 | 0,010811 |
| RouteGovernor | 1 573 101 | 0,007866 |
| CotejoAggregatorAdapter × 3 | 1 599 689 | 0,007998 |
| `setGovernor` | 65 581 | 0,000328 |
| **Fase 1 total** | **10 301 359** | **0,051507** |
| Fase 2 (configuración + 3 rutas) | ~1 700 000 | ~0,0085 |
| Fase 3 (ejecutar 3 rutas) | ~900 000 | ~0,0045 |
| **Total** | **~12,9 M** | **~0,065** |

**Cabe entero en una sola reclamación del faucet**, con ~7× de margen sobre los 0,5 WBT. Con el
buffer conservador de `forge` (estima a 10 gwei, el doble del base fee) sigue siendo ~0,13 WBT.

El cuello de botella real **no es el gas: es el timelock de 48 h** entre proponer y ejecutar
rutas. El despliegue es una operación de tres días como mínimo, por diseño (INV-4).

### Por qué los scripts son reanudables de todos modos

El presupuesto no aprieta, pero el RPC público limita a 50 req/s por IP y una fase puede morir
a mitad. Cada script comprueba, contrato a contrato, si la dirección registrada en
`deployments/1874.json` **todavía tiene bytecode en cadena**; si no lo tiene, redespliega.

El JSON es una caché, nunca la fuente de verdad — la cadena lo es. Una ejecución que registre
una dirección y falle antes de que la transacción aterrice deja una entrada obsoleta, y la
siguiente ejecución la detecta y la corrige sola.

### `AggregationLib` no se despliega

Sus cuatro funciones son `internal`, así que solc las inlinea en cada consumidor y la librería
compila a un stub de 85 bytes que nadie enlaza. Desplegarla dejaría un contrato muerto en el
explorer y gastaría gas sin producir ningún enlace. Está deliberadamente ausente del script.

---

## 3. Requisitos previos

```bash
# 1. Keystore cifrado. Nunca una clave en texto plano, ni en testnet.
cast wallet import cotejo-deployer --interactive

# 2. Fondear desde el faucet
#    https://faucet.testnet.whitechain.io  (GitHub OAuth, cuenta de 30+ días)

# 3. Confirmar saldo
cast balance <tu-dirección> --rpc-url https://rpc.testnet.whitechain.io
```

Variables de entorno (ninguna se versiona):

```bash
export COTEJO_OWNER=0x...              # multisig en producción; por defecto, el deployer
export COTEJO_GUARDIAN=0x...           # único rol que puede pausar
export COTEJO_REPORTER_WGROUP=0x...    # clave del reporter de cada grupo
export COTEJO_REPORTER_BINANCE=0x...
export COTEJO_REPORTER_KRAKEN=0x...
export COTEJO_MIN_DEPTH_USD=250000
```

---

## 4. Despliegue

### Fase 1 — contratos

```bash
forge script script/01_Deploy.s.sol:Deploy \
  --rpc-url https://rpc.testnet.whitechain.io \
  --account cotejo-deployer \
  --broadcast --slow \
  --verify --verifier blockscout \
  --verifier-url https://explorer.testnet.whitechain.io/api/
```

`--slow` envía las transacciones en secuencia, lo que hace que un fallo a mitad deje un estado
limpio y reanudable. Requiere TTY para la contraseña del keystore: ejecútalo tú, no un agente.

Despliega, en orden de menor a mayor riesgo: las tres `AttestationSource` (independientes entre
sí, las más baratas de rehacer), el `PriceRouter`, el `RouteGovernor`, los tres adaptadores, y
por último `setGovernor`, que es la única llamada irreversible de la fase — se puede hacer
exactamente una vez, y después el deployer pierde todo poder sobre rutas, pausa y precios.

Si `COTEJO_OWNER` no es el deployer, el script no intenta `setGovernor` (revertiría el
broadcast entero): imprime la llamada para que la haga el owner.

### Fase 2 — configuración y propuesta de rutas

```bash
forge script script/02_Configure.s.sol:Configure \
  --rpc-url https://rpc.testnet.whitechain.io \
  --account cotejo-deployer --broadcast --slow
```

Habilita los tres activos en las tres fuentes, registra las claves de reporter, nombra al
guardián, y propone una ruta por par con los parámetros acordados:

```
minSources                 = 3
maxDeviationBps            = 200
maxStalenessSeconds        = 900
reporterHeartbeatSeconds   = 300     # D2 exige staleness >= 2 × heartbeat
maxSourcesPerOperatorGroup = 1       # INV-5
```

El orden lo imponen los contratos, no la preferencia: `proposeRoute` ejecuta `validateRoute`,
que exige que toda fuente nombrada responda `supportsAsset(asset) == true`, así que `setAsset`
tiene que aterrizar antes o la propuesta revierte.

> Con `minSources = 3` y un operador por fuente, **los tres grupos deben estar reportando para
> que exista precio**. Es la postura pretendida: el oráculo se niega a responder hasta que el
> conjunto completo de reporters está vivo.

### Fase 3 — ejecutar rutas (48 h después)

```bash
forge script script/03_ExecuteRoutes.s.sol:ExecuteRoutes \
  --rpc-url https://rpc.testnet.whitechain.io \
  --account cotejo-deployer --broadcast --slow
```

La ejecución es **permissionless**: cualquier cuenta con fondos puede empujar una propuesta
madura. El owner propone y puede cancelar, pero no puede bloquear un cambio maduro callándose.

`commitRoute` revalida al ejecutar. Una ruta que era sólida al proponerse y ha derivado desde
entonces — típicamente porque el `operatorGroup` de una fuente se movió — **no aterriza** en
lugar de instalar algo que viole INV-5 nada más llegar. Si pasa, arregla la fuente y vuelve a
proponer; no lo fuerces.

Si algún timelock aún no ha vencido, el script imprime los segundos restantes y sale. Vuelve a
ejecutarlo.

---

## 5. Verificación en Blockscout

**La sintaxis de Blockscout difiere de la de Etherscan.** El detalle que rompe la verificación:

> `--verifier-url` de Foundry termina en **`/api/` con barra final**. Hardhat usa `/api` sin
> barra. Cada forma es correcta para su herramienta y no son intercambiables.

Verificación durante el despliegue (recomendado): añade a `forge script`

```
--verify --verifier blockscout --verifier-url https://explorer.testnet.whitechain.io/api/
```

Verificación posterior, contrato a contrato:

```bash
# Sin argumentos de constructor
forge verify-contract <address> src/PriceRouter.sol:PriceRouter \
  --rpc-url https://rpc.testnet.whitechain.io \
  --verifier blockscout \
  --verifier-url https://explorer.testnet.whitechain.io/api/
```

```bash
# AttestationSource — cinco argumentos de constructor
forge verify-contract <address> src/sources/AttestationSource.sol:AttestationSource \
  --rpc-url https://rpc.testnet.whitechain.io \
  --verifier blockscout \
  --verifier-url https://explorer.testnet.whitechain.io/api/ \
  --constructor-args $(cast abi-encode \
    "constructor(string,string,bytes32,bytes32,address)" \
    "Cotejo" "1" \
    $(cast keccak "cotejo.source.wgroup") \
    $(cast keccak "wgroup") \
    <owner-address>)
```

```bash
# RouteGovernor
forge verify-contract <address> src/RouteGovernor.sol:RouteGovernor \
  --rpc-url https://rpc.testnet.whitechain.io \
  --verifier blockscout \
  --verifier-url https://explorer.testnet.whitechain.io/api/ \
  --constructor-args $(cast abi-encode "constructor(address,address)" <router> <owner>)

# CotejoAggregatorAdapter
forge verify-contract <address> src/adapters/CotejoAggregatorAdapter.sol:CotejoAggregatorAdapter \
  --rpc-url https://rpc.testnet.whitechain.io \
  --verifier blockscout \
  --verifier-url https://explorer.testnet.whitechain.io/api/ \
  --constructor-args $(cast abi-encode "constructor(address,bytes32,uint8,string)" \
    <router> $(cast keccak "WBT/USD") 8 "WBT/USD")
```

Comprobar el resultado:

```bash
curl -s "https://explorer.testnet.whitechain.io/api/v2/smart-contracts/<address>" \
  | jq '{name, is_verified, is_fully_verified, verified_via_sourcify}'
```

Si `--verify` falla o el contrato tiene varios ficheros fuente, usa el método
`standard-input` de Blockscout. Los métodos disponibles se listan en
`GET /api/v2/smart-contracts/verification/config`.

**Compilador:** `v0.8.24+commit.e11b9ed9`, EVM `shanghai`, optimizer activado, 200 runs. Esa
versión está confirmada en la lista de compiladores del explorer. Los ajustes deben coincidir
exactamente con `foundry.toml` o la verificación falla por mismatch de bytecode.

---

## 6. Panel de verificación

`panel/index.html`. Un solo fichero, sin build step, sin servidor: ábrelo desde el sistema de
ficheros.

```bash
# macOS / Linux
open panel/index.html
# Windows
start panel\index.html
```

Pega la dirección del `PriceRouter` y del `RouteGovernor` (están en `deployments/1874.json`), o
pásalas por URL:

```
panel/index.html?router=0x...&governor=0x...
```

Muestra, por par: precio y bloque de lectura, las tres fuentes con su operador, precio
individual, antigüedad en segundos, profundidad USD reportada y firmante; la desviación actual
en bps con el margen que queda antes de que el router revierta; cualquier cambio de ruta
pendiente con cuenta atrás; y el estado de pausa. Cada dirección enlaza al explorer.

Todas las lecturas de un ciclo se agrupan en un solo `eth_call` vía Multicall3 y se fijan al
mismo `blockNumber`, así que los valores de una tarjeta son mutuamente consistentes y
comprobables contra ese bloque. Sin eso, veinte lecturas gastarían veinte de los 50 req/s.

**Cuando el router revierte, el panel lo trata como un éxito.** La tarjeta pasa a
«Protegiendo» en ámbar, no a rojo de error, y muestra el error tipado, la invariante que lo
produjo y una frase explicando qué se detuvo. Un oráculo que se niega a responder está
funcionando.

---

## 7. Guion de la prueba en vivo

`script/LiveTest.s.sol`. Demuestra la afirmación central del sistema contra la cadena real: un
reporter comprometido no puede mover el precio publicado, y el fallo es ruidoso, tipado e
inmediato.

```bash
export COTEJO_DEMO_MNEMONIC="..."        # desechable, solo testnet, nunca versionado
export COTEJO_DEMO_PAIR="WBT/USD"

forge script script/LiveTest.s.sol:LiveTest \
  --rpc-url https://rpc.testnet.whitechain.io \
  --account cotejo-deployer --broadcast --slow -vv
```

### Guion para grabar

| Momento | Acción | Qué se ve |
|---|---|---|
| 0:00 | Panel abierto, auto-refresco activado | Par en **Sirviendo**, tres fuentes verdes, desviación ~0 bps, margen 200 |
| 0:15 | Señalar la tabla de fuentes | Tres `operatorGroup` distintos: `wgroup`, `binance`, `kraken`. INV-5 en acción |
| 0:30 | Ejecutar `LiveTest` en una terminal al lado | El script imprime `[SERVING]` tras la línea base |
| 0:45 | El script inyecta ×100 en una sola fuente | Consola: `[REFUSING] Cotejo__DeviationExceeded (INV-2)` |
| 1:00 | Volver al panel, recargar | La tarjeta pasa a **Protegiendo**, ámbar |
| 1:10 | Leer la tarjeta en voz alta | `Cotejo__DeviationExceeded`, etiqueta `INV-2`, 990 000 bps contra un límite de 200 |
| 1:25 | Señalar la tabla | La fuente mentirosa muestra su precio ×100; las otras dos siguen intactas |
| 1:40 | Cerrar | «El precio no se movió. El oráculo dejó de responder, que es lo que tenía que hacer» |

Los números son exactos y están fijados en un test: con `[100, 100, 10000]` la mediana es 100,
el spread 9 900, y la desviación **990 000 bps** contra un límite de 200. Ver
`test/scenarios/LiveDemo.t.sol`, que ensaya esta secuencia completa contra los contratos
reales con firmas EIP-712 reales.

### Detalle que hace que el demo funcione

La línea base se sella con `observedAt = now - 1` y la anomalía con `observedAt = now`.
`AttestationSource` exige que las observaciones avancen estrictamente en el tiempo, así que sin
ese desfase la inyección se rechazaría como replay antes de llegar al router. Está fijado en
`test_LiveDemo_injectionAtSameTimestampWouldBeRejectedAsReplay`.

---

## 8. Qué puede comprobar un tercero, sin confiar en nosotros

Todo lo siguiente se lee de la cadena, con el RPC público y las direcciones de
`deployments/1874.json`:

| Afirmación | Cómo se comprueba |
|---|---|
| No existe función para escribir un precio | El ABI verificado del `PriceRouter` en Blockscout no tiene ningún setter de precio (INV-7) |
| Las rutas exigen tres operadores distintos | `getRoute(asset)` → `maxSourcesPerOperatorGroup == 1`, y `operatorGroupOf` de cada fuente devuelve grupos distintos |
| Los cambios de ruta esperan 48 h | `RouteGovernor.ROUTE_TIMELOCK()` y `getPendingRoute(asset)` con su `eta`, legible durante toda la espera |
| La profundidad reportada es real | `AttestationSource.latestObservation(asset)` devuelve `depthUsd` y el firmante |
| Las atestaciones están firmadas por claves registradas | `hashAttestation` reproduce el digest EIP-712; `isAuthorised(reporter, asset)` confirma la autorización |
| El oráculo se niega cuando debe | Llamar a `latestPrice` durante el demo devuelve un error tipado, no un precio |

---

## 9. Estado actual y lo que falta

**Desplegado:** nada todavía. Los scripts, el panel y el demo están listos y probados; el
broadcast requiere TTY para la contraseña del keystore, así que lo ejecutas tú.

**La fase 1B (reporters off-chain) no existe en este repositorio.** Se propuso la interfaz del
adaptador y el esquema YAML y quedó pendiente de aprobación. Consecuencia práctica: hasta que
haya reporters publicando, el panel mostrará **Protegiendo ·
`Cotejo__InsufficientSources`** en los tres pares, que es el comportamiento correcto para un
oráculo sin datos.

El demo en vivo no depende de ellos: `LiveTest.s.sol` firma sus propias atestaciones con
firmas EIP-712 reales contra los contratos desplegados, así que la demostración corre
autónoma. Un demo que necesita tres servicios externos levantados es un demo que no corre
cuando lo necesitas.
