# Cotejo · Despliegue en Whitechain Sepolia

Guion completo para desplegar, verificar y demostrar Cotejo en testnet, y para que un tercero
compruebe que funciona sin confiar en nosotros.

---

## 0. Acciones pendientes con fecha

Horas en **Santiago de Chile (UTC−3**, horario de verano desde el 6 de septiembre de 2026). El
reloj que manda es el de la cadena, en UTC; la columna local existe para no calcularla a mano a
las tres de la mañana.

| # | Acción | Santiago | UTC | Estado |
|---|---|---|---|---|
| 1 | `03_ExecuteRoutes` — instala la ruta WBT/USD | dom 20 sep, 12:19 | 20 sep 15:19 | **HECHO** 15:21 UTC |
| 2 | Ejecutar la concesión del guardián | **dom 20 sep, 19:23** | 20 sep 22:23 | pendiente — timelock A6.3 |
| 3 | Publicar la página pública | ya desbloqueado | — | pendiente — `site/index.html` |

### El oráculo empezó a servir, 15:21 UTC

Transacción [`0x19384cca…6d96f`](https://explorer.testnet.whitechain.io/tx/0x19384cca0b5cbf91e46ffbb857e3569f317c3858e0c0f0ec529d51106ae5d96f),
bloque 8321339, 288 909 gas a 5 gwei = 0,00144 WBT. Leído de la cadena, no del log:

```
router    latestPrice(WBT/USD)  ->  82332500000000000000  18 dec
adapter   latestRoundData()     ->          8233250000    8 dec  = 82,33250000
updatedAt                             1789916905
```

Los dos valores coinciden: el adaptador reescala de 18 a 8 decimales correctamente. `updatedAt`
es la observación **más antigua** del conjunto, no la más nueva.

Un detalle de coste, consistente con lo medido en la fase 1: forge estimó 10 gwei y la red cobró
5. La estimación duplica sistemáticamente en esta cadena.

Durante las 48 h anteriores el adaptador revirtió con `Cotejo__RouteNotConfigured`. Eso no fue
una espera muerta: fue el sistema funcionando. Había contratos desplegados y precios reales
llegando, y aun así no había respuesta defendible que dar, así que no dio ninguna.

Las dos primeras son permissionless una vez vencido el timelock: cualquiera puede ejecutarlas,
no hacen falta privilegios. Lo que no se puede es adelantarlas.

Hay **7 horas entre los dos timelocks** porque la ruta se encoló antes que el guardián. En este
despliegue no importa —sin mercado desplegado, una pausa no defendería nada— pero el orden
correcto es al revés: encolar primero el guardián, para que la capacidad de parar exista antes
que la capacidad de servir.

Comando de la acción 1, en una sola línea:

```powershell
forge script script/03_ExecuteRoutes.s.sol:ExecuteRoutes --rpc-url https://rpc.testnet.whitechain.io --account cotejo-deployer --broadcast --slow
```

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


## 1-bis. Qué está desplegado

Fase 1 en Whitechain Sepolia (chain id 1874), 18 de septiembre de 2026. Los ocho contratos
están **verificados** en Blockscout.

| Contrato | Dirección |
|---|---|
| `PriceRouter` | [`0xB4f9C2151B73eDEa730A72e9642C971d803Fd096`](https://explorer.testnet.whitechain.io/address/0xB4f9C2151B73eDEa730A72e9642C971d803Fd096) |
| `RouteGovernor` | [`0x116a41d02bF43f7c15D9DB8EC3e0fDccAE55341D`](https://explorer.testnet.whitechain.io/address/0x116a41d02bF43f7c15D9DB8EC3e0fDccAE55341D) |
| `AttestationSource` cotejo-keeper-1 | [`0x78cce8C167583bf358B3EA1c9C409e13A7Da691a`](https://explorer.testnet.whitechain.io/address/0x78cce8C167583bf358B3EA1c9C409e13A7Da691a) |
| `AttestationSource` cotejo-keeper-2 | [`0x5886F06c5cD7eC7E07396D4787fca22A965032C5`](https://explorer.testnet.whitechain.io/address/0x5886F06c5cD7eC7E07396D4787fca22A965032C5) |
| `AttestationSource` cotejo-keeper-3 | [`0x5eD6fe0C2bF02227153CC5482f7d316475a11625`](https://explorer.testnet.whitechain.io/address/0x5eD6fe0C2bF02227153CC5482f7d316475a11625) |
| `AttestationSource` cotejo-keeper-4 | [`0x8A65a9ae5057eB846ce06c1E890f0aB8ADB05777`](https://explorer.testnet.whitechain.io/address/0x8A65a9ae5057eB846ce06c1E890f0aB8ADB05777) |
| `AttestationSource` cotejo-keeper-5 | [`0x99D1beDEa8d628b2Bd1Cd136F3348d1d680D6682`](https://explorer.testnet.whitechain.io/address/0x99D1beDEa8d628b2Bd1Cd136F3348d1d680D6682) |
| `CotejoAggregatorAdapter` WBT/USD | [`0xc7624150c28bF26cdF920A0715a7c0ba614faE16`](https://explorer.testnet.whitechain.io/address/0xc7624150c28bF26cdF920A0715a7c0ba614faE16) |

Comprobado leyendo la cadena, no el log del despliegue:

- Los ocho tienen bytecode.
- `router.governor()` y `governor.ROUTER()` se apuntan mutuamente: `setGovernor` se ejecutó y ya
  no puede repetirse.
- `ROUTE_TIMELOCK` = 172 800 s = 48 h exactas.
- Los cinco `operatorGroup` on-chain son `keccak("cotejo-keeper-N")`, leídos del evento
  `OperatorGroupUpdated` de cada recibo. Ninguna identidad de exchange quedó escrita.
- `adapter.ASSET()` = `keccak("WBT/USD")`, `decimals()` = 8, `description()` = `"WBT/USD"`.

**El oráculo todavía se niega, y eso es correcto.** `latestRoundData()` revierte con
`Cotejo__RouteNotConfigured` (`0xf13fd686`): los contratos están en cadena pero no hay ruta
instalada, así que no hay precio. Servirá cuando la fase 3 ejecute la ruta, 48 h después de que
la fase 2 la encole.

### Fase 2, completada el 18 de septiembre de 2026

| Qué | Estado |
|---|---|
| `WBT/USD` habilitado en las cinco fuentes | hecho |
| Cinco reporters autorizados | hecho, `isReporter` e `isAuthorised` = `true` en las cinco |
| Guardián `0xdAB216…b8f1` | **encolado**, ejecutable 2026-09-20 22:23 UTC |
| Ruta `WBT/USD` | **encolada**, ejecutable 2026-09-20 15:19 UTC |

Parámetros de la ruta encolada, leídos del governor: cinco fuentes,
`minSources = 3`, `maxDeviationBps = 200`, `maxStalenessSeconds = 1800`,
`reporterHeartbeatSeconds = 900`, `maxSourcesPerOperatorGroup = 1`.

**Los dos timelocks no vencen a la vez, y la diferencia son 7 horas.** La ruta se
encoló antes que el guardián, así que entre las 15:19 y las 22:23 del día 20 el
oráculo sirve precio sin que nadie pueda pausarlo.

Se deja así a propósito, y la razón importa: pausar un activo protege a los
contratos que lo leen, y hoy no hay ninguno — el mercado no está desplegado. Una
pausa en esa ventana no defendería nada, y esperar siete horas costaría siete
horas de uptime, que es la única métrica que este despliegue acumula dejándolo
correr. **Si hubiera un mercado en vivo la decisión sería la contraria**: se
esperaría, o se habría encolado el guardián primero.

La lección operativa, para la próxima vez: **el guardián se encola antes que la
ruta**, porque su timelock corre en paralelo y no cuesta nada adelantarlo.

### Primer precio en cadena, 18 de septiembre de 2026

El keeper publicó su primer ciclo a las 22:32 UTC. Cinco atestaciones EIP-712,
una por fuente, relayadas por `0xE6997E2b3b1952dd9333845c64961F8ab872A516`:

| Fuente | Hash |
|---|---|
| cotejo-keeper-1 | [`0xaa347add…af7d`](https://explorer.testnet.whitechain.io/tx/0xaa347add0c00b01f0bbe950830455b0c9aefb791ed7ce5b78f2f5f4aae9eaf7d) |
| cotejo-keeper-2 | [`0xa0811607…1fe8`](https://explorer.testnet.whitechain.io/tx/0xa081160768a560a957d3294262ab6691b54e9ba4ac5312fee22f1aaa62a51fe8) |
| cotejo-keeper-3 | [`0x5cfb3fe8…77a8`](https://explorer.testnet.whitechain.io/tx/0x5cfb3fe8be4ba210d2f5ac02a297c8210e93f8f9b5040c2f05744d9dd6b377a8) |
| cotejo-keeper-4 | [`0xdb03030f…f0ce`](https://explorer.testnet.whitechain.io/tx/0xdb03030f3fdf015c2868dd11bf9aeb1d73abc11e91ed9188d5bc674f1a9ef0ce) |
| cotejo-keeper-5 | [`0xbd657ebf…7653`](https://explorer.testnet.whitechain.io/tx/0xbd657ebf4730202e18ad1b22a20f459d012bddfda9c2668bbcc92e0b1ffa7653) |

Lo almacenado, leído de las cinco con `latestObservation`:

```
price      83.348500000000000000   WBT/USD, 18 decimales
depthUsd   668760                  suelo configurado: 250000
observedAt 1789770763
reporter   distinto en cada fuente
group      keccak("cotejo-keeper-N"), distinto en cada fuente
```

**Los cinco precios son idénticos bit a bit. La desviación es 0,00 bps contra una
tolerancia de 200.** No es una coincidencia afortunada: es la consecuencia
aritmética de que un proceso lea un libro y firme cinco veces. INV-2 rechaza un
conjunto cuyo diferencial supera la tolerancia de la ruta, y aquí no disparará
nunca, porque cinco firmas sobre un mismo número no pueden discrepar.

El invariante no está roto: está **inactivo**, y seguirá inactivo hasta que los
cinco precios vengan de cinco sitios. Conviene decirlo así, con el número
delante, porque un panel verde hoy demuestra agregación, frescura, quórum y
concentración de operador funcionando sobre datos reales — y no demuestra nada
sobre la comprobación de desviación, que es la que la gente asume que lo demuestra
todo.

El router sigue negando el precio con `Cotejo__RouteNotConfigured` hasta que la
ruta se instale. Los datos están en las fuentes; lo que falta es la ruta que los
agrega.

**Lo que no está desplegado:** el mercado de préstamo. Con las rutas aún sin instalar no
satisface sus propias reglas de admisión, y la regla no se debilita para que quepa.


### El keeper deja de depender de una máquina, 23:07 UTC

El bucle local dura lo que dure la sesión de terminal. Desde las **23:07 UTC del
18 de septiembre de 2026** el latido lo publica
[`.github/workflows/keeper.yml`](.github/workflows/keeper.yml) en GitHub
Actions. Ahí arranca el reloj de uptime que la solicitud cita.

Ese primer diseño pedía el latido al planificador de GitHub, con un cron de diez
minutos. **Disparó una vez en 4 h 48 min**, y la observación en cadena llegó a
tener 2 h 44 min contra una tolerancia de 1800 s. Corregido el 19 de septiembre:
ahora un proceso vive 5 h 45 min marcando su propio ritmo de 900 s y al cron solo
se le pide que aterrice una vez dentro de esa ventana. El detalle y el porqué
están en [`keeper/README.md`](keeper/README.md).

Primer ciclo alojado, confirmado con `cast receipt` (`status = 1` en las cinco) y
releyendo las fuentes con `latestObservation`, no fiándose del log:

| Fuente | Hash |
|---|---|
| cotejo-keeper-1 | [`0xa5be7cb2…c89c`](https://explorer.testnet.whitechain.io/tx/0xa5be7cb22c33b3d3439f8339780a3505692d878ffc98f88ba6aee4ff6cd8c89c) |
| cotejo-keeper-2 | [`0xd5ad0a16…c400`](https://explorer.testnet.whitechain.io/tx/0xd5ad0a163d191e30a71eddbb60f4678fe3e848163e8200f6360f21dd264dc400) |
| cotejo-keeper-3 | [`0x96a280b2…3d30`](https://explorer.testnet.whitechain.io/tx/0x96a280b226590f7c7731e1b736b051e011d0f0829d373d2e1ceb1a6716023d30) |
| cotejo-keeper-4 | [`0xe2f69085…6f3e`](https://explorer.testnet.whitechain.io/tx/0xe2f69085fba7a5ab3ef990e31489176ac2d8170aa534645a4adffb00861e6f3e) |
| cotejo-keeper-5 | [`0x52977f1f…ca9f`](https://explorer.testnet.whitechain.io/tx/0x52977f1f40a45f7f18c62650707eb76b27986436e63b7f25a402a3476627ca9f) |

```
price      83.198500000000000000   WBT/USD, 18 decimales
depthUsd   652391                  suelo configurado: 250000
observedAt 1789772851
```

La desviación sigue siendo 0,00 bps, por la misma razón aritmética de siempre.
Alojar el keeper no cambia nada de eso: mueve el punto único de fallo de un
portátil a GitHub, no lo elimina.

#### Lo que falló primero, que es la parte útil

El primer disparo salió en rojo con las cinco fuentes en `not authorised` y el
relayer a 0 WBT. Causa: el secreto contenía **otra mnemónica**, no la que
`02_Configure` autorizó. BIP-39 lleva checksum, así que una palabra mal copiada
habría lanzado un error de mnemónica inválida — que derivara cinco direcciones
válidas pero distintas probaba que era una semilla entera diferente, no una
transcripción rota.

Lo relevante no es el fallo sino cómo se vio. Hasta ese día `npm run once` salía
con código 0 aunque los cinco `submit` se saltaran, y un runner programado
reporta éxito por el código de salida: la ejecución habría salido **verde**, sin
publicar un solo precio, sumando un latido a un historial de uptime inexistente.
Un ciclo que no publica nada ahora sale distinto de cero. La regla general: la
telemetría que solo sabe decir que sí no es telemetría.


## 2. Presupuesto

### Coste único: desplegar — **medido**, no estimado

Cifras de los recibos reales de la fase 1 en Whitechain Sepolia, 18 de septiembre de 2026.
Ya no son una simulación.

| Contrato | Gas L2 | WBT |
|---|---:|---:|
| AttestationSource × 5 | 7 007 625 | 0,035038 |
| PriceRouter | 1 885 619 | 0,009428 |
| RouteGovernor | 1 433 916 | 0,007170 |
| CotejoAggregatorAdapter | 410 193 | 0,002051 |
| `setGovernor` | 47 391 | 0,000237 |
| **Total fase 1** | **10 784 744** | **0,053924** |

Gasto real contra el saldo: 50,500000 → 50,446018 WBT, es decir **0,053981 WBT**. La diferencia
de 0,000058 WBT frente a la tabla es la tarifa de datos L1, abajo.

`forge` estimó 14 024 011 de gas y se gastaron 10 784 744: **un 23 % menos**. Su estimación
lleva un colchón deliberado y además asume 10 gwei cuando la red cobró 5. Presupuestar con la
cifra de `forge` es correcto; creer que es el coste, no.

### La tarifa de datos L1, por fin con un recibo

Este documento decía que el componente L1 de una OP Stack no estaba en ninguno de nuestros
números y que solo saldría de un recibo. Salió del recibo de la primera `AttestationSource`
(`0x9831105d…`):

| | |
|---|---:|
| Gas L2 | 1 401 525 a 5,000 gwei = 0,00700763 WBT |
| Gas L1 | 69 651 a 1,0995 gwei = **0,00000792 WBT** |
| L1 como fracción del L2 | **0,11 %** |

Es despreciable. El presupuesto del keeper tenía reservada la mitad del faucet para este
componente y resultó necesitar la milésima parte. Lo que `forge` imprime como `Paid` es solo el
L2; el total real es ~0,1 % mayor.

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

A ese número hay que sumarle la tarifa de datos L1, que ahora está medida: **+0,11 %**, unos
0,00016 WBT al día. Este documento decía "presupuestar al doble hasta tenerlo"; con el recibo
delante, esa reserva sobraba por tres órdenes de magnitud.

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

### Antes de copiar nada: PowerShell no entiende `\`

Todos los bloques de este documento están escritos para un shell POSIX, donde `\` al final
de la línea continúa el comando. **En PowerShell `\` no es continuación**: el carácter de
continuación es el acento grave. Pegar un comando con `\` en PowerShell no da un error de
sintaxis — es peor: cada `\` se convierte en un **argumento posicional más**, y
`forge script` pasa los argumentos posicionales a la función que va a llamar.

Como `run()` no acepta argumentos ni devuelve nada, el resultado es:

```
Error: encode length mismatch: expected 0 types, got 2
```

Dos `\` pegados, dos argumentos de más, "got 2". El mensaje no menciona el shell ni los
argumentos, así que se lee como un fallo del script cuando no lo es.

En Windows, **pega cada comando en una sola línea**.

### Fase 1 — contratos

```bash
forge script script/01_Deploy.s.sol:Deploy \
  --rpc-url https://rpc.testnet.whitechain.io \
  --account cotejo-deployer \
  --broadcast --slow \
  --verify --verifier blockscout \
  --verifier-url https://explorer.testnet.whitechain.io/api/
```

Una sola línea, para PowerShell o cmd:

```powershell
forge script script/01_Deploy.s.sol:Deploy --rpc-url https://rpc.testnet.whitechain.io --account cotejo-deployer --broadcast --slow --verify --verifier blockscout --verifier-url https://explorer.testnet.whitechain.io/api/
```

`--slow` envía las transacciones en secuencia, lo que hace que un fallo a mitad deje un estado
limpio y reanudable. Requiere TTY para la contraseña del keystore: ejecútalo tú, no un agente.

Despliega, en orden de menor a mayor riesgo: las cinco `AttestationSource` (independientes entre
sí, las más baratas de rehacer), el `PriceRouter`, el `RouteGovernor`, el adaptador WBT/USD, y
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

```powershell
forge script script/02_Configure.s.sol:Configure --rpc-url https://rpc.testnet.whitechain.io --account cotejo-deployer --broadcast --slow
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
