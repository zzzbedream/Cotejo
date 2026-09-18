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

**Estimado por simulación, no medido en cadena.** Las cifras salen de `forge script` simulando
contra el RPC real (chain id 1874 confirmado) e incluyen el colchón que `forge` añade sobre el
gas estimado. No son recibos. La columna en WBT las convierte al base fee mínimo real de la red
(5 gwei); `forge` estima a 10 gwei, así que él mismo pedirá el doble.

### Coste único: desplegar

| Contrato | Gas | WBT @ 5 gwei |
|---|---:|---:|
| AttestationSource × 5 | 9 108 585 | 0,045543 |
| PriceRouter | 2 451 039 | 0,012255 |
| RouteGovernor | 1 863 825 | 0,009319 |
| CotejoAggregatorAdapter × 1 | 533 250 | 0,002666 |
| `setGovernor` | 65 457 | 0,000327 |
| **Fase 1 total** | **14 022 156** | **0,070111** |

Fases 2 y 3 (configurar fuentes, proponer la ruta, ejecutarla tras el timelock) **todavía no
son simulables**: sus scripts exigen que las direcciones de la fase 1 tengan bytecode en cadena,
y no lo tienen. Se medirán cuando la fase 1 aterrice. No hay una estimación aquí porque
inventarla sería peor que su ausencia.

La fase 1 cabe entera en una sola reclamación del faucet (0,5 WBT), con ~7× de margen.

### Coste recurrente: mantener el latido

Esto es lo que de verdad limita el despliegue, y la versión anterior de este documento no lo
tenía en cuenta.

| Concepto | Valor | Origen |
|---|---:|---|
| `submit` en régimen permanente | 34 526 gas | medido en `test_steadyStateSubmitFitsTheFaucetBudget` |
| `submit` como transacción | ~61 222 gas | + 21 000 intrínseco + calldata a 16 gas/byte |
| Latidos por día | 96 | heartbeat de 900 s |
| `submit` por día | 480 | 96 × 5 fuentes × 1 par |
| **Coste diario** | **~0,147 WBT** | 480 × 61 222 × 5 gwei |

Cabe en el faucet —es el 29 % del tope diario— pero **es un coste perpetuo, no un pago único**.
Mantener el oráculo vivo tres semanas cuesta ~3,1 WBT, lo que obliga a reclamar el faucet cada
tres días como mínimo. La reclamación es manual y pasa por OAuth de GitHub: no se puede
automatizar. Un latido que se detiene produce `Cotejo__StalePrice`, que es el comportamiento
correcto y es indistinguible, para quien mire desde fuera, de un despliegue roto.

**Ese número no incluye la tarifa de datos L1.** Whitechain es una OP Stack y cobra un
componente L1 por transacción que ninguna simulación local observa. La cifra real solo sale de
un recibo. Presupuestar al doble hasta tenerlo.

El otro cuello de botella **no es el gas: es el timelock de 48 h** entre proponer y ejecutar
rutas. El despliegue es una operación de tres días como mínimo, por diseño (INV-4).

### Una simulación ensucia el fichero de estado

`forge script` sin `--broadcast` ejecuta igualmente los `vm.writeJson` del script, así que una
simulación deja `deployments/1874.json` lleno de direcciones que no existen en ninguna cadena.
Tras cualquier ensayo:

```bash
git checkout -- deployments/1874.json
```

Sin ese paso el repositorio anuncia un despliegue que no ocurrió, que es exactamente la
afirmación que este proyecto no puede permitirse.

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

Variables de entorno: copiar la plantilla y rellenarla.

```bash
cp .env.example .env
```

`.env` está en `.gitignore`; `.env.example` no, así que la plantilla no lleva ningún valor real.
Las variables son:

| Variable | Qué es | ¿Secreto? |
|---|---|---|
| `COTEJO_OWNER` | Dueño de router, governor y fuentes. Vacío = el propio deployer | No |
| `COTEJO_GUARDIAN` | Único rol que puede pausar. Concederlo espera 48 h (A6.3) | No |
| `COTEJO_REPORTER_1..5` | Una **dirección** de reporter por grupo de operador | No |
| `COTEJO_MIN_DEPTH_USD` | Profundidad mínima declarada para aceptar una atestación | No |
| `COTEJO_DEMO_MNEMONIC` | Mnemónico desechable de `LiveTest.s.sol` | **Sí** |

`COTEJO_REPORTER_1..5` son direcciones, no claves. Lo que autoriza una escritura en
`AttestationSource` es la firma EIP-712, no el `msg.sender`; estas variables solo dicen de quién
se acepta esa firma. Una variable sin valor deja esa fuente sin reporter autorizado, que es
seguro — no puede producir precio — y el script lo reporta como aviso.

### La clave del deployer no vive en `.env`

Foundry firma desde un keystore cifrado. Una clave en un `.env` está en claro en el disco, entra
en el historial del shell en cuanto se hace `export`, y aparece en `ps` y en cualquier volcado de
proceso. El keystore pide la contraseña por TTY y nunca escribe la clave en claro.

Eso también significa que **ningún agente puede ejecutar estos comandos**: el prompt de
contraseña necesita una terminal interactiva. Los ejecuta una persona.

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

Habilita el par en las cinco fuentes, registra las claves de reporter, nombra al guardián, y
propone la ruta con los parámetros acordados:

```
minSources                 = 3
maxDeviationBps            = 200
maxStalenessSeconds        = 1800
reporterHeartbeatSeconds   = 900     # D2 exige staleness >= 2 × heartbeat
maxSourcesPerOperatorGroup = 1       # INV-5
```

El heartbeat es 900 s y no 300 s por presupuesto, no por preferencia: ver la sección 2. Cinco
fuentes sobre un par cada 900 s cuestan ~0,147 WBT/día; a 300 s sobre tres pares no cabe en el
faucet.

El orden lo imponen los contratos, no la preferencia: `proposeRoute` ejecuta `validateRoute`,
que exige que toda fuente nombrada responda `supportsAsset(asset) == true`, así que `setAsset`
tiene que aterrizar antes o la propuesta revierte.

> Con `minSources = 3` sobre cinco fuentes y un operador por fuente, **tres de los cinco grupos
> deben estar reportando para que exista precio**. Los dos de margen son deliberados: con
> exactamente tres fuentes, un solo tropiezo del keeper deja el par sin precio, y una negativa
> por falta de quórum es indistinguible desde fuera de un despliegue caído.

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
    $(cast keccak "cotejo.source.cotejo-keeper-1") \
    $(cast keccak "cotejo-keeper-1") \
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

Muestra, por par: precio y bloque de lectura, las cinco fuentes con su operador, precio
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
| 0:00 | Panel abierto, auto-refresco activado | Par en **Sirviendo**, cinco fuentes verdes, desviación ~0 bps, margen 200 |
| 0:15 | Señalar la tabla de fuentes | Cinco `operatorGroup` distintos, `cotejo-keeper-1..5`. INV-5 en acción — y las cinco claves son nuestras: la regla se cumple, la independencia todavía no existe |
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
`Cotejo__InsufficientSources`** en el par, que es el comportamiento correcto para un
oráculo sin datos.

El demo en vivo no depende de ellos: `LiveTest.s.sol` firma sus propias atestaciones con
firmas EIP-712 reales contra los contratos desplegados, así que la demostración corre
autónoma. Un demo que necesita tres servicios externos levantados es un demo que no corre
cuando lo necesitas.
