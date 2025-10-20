# KipuBankV3

Resumen rápido
- KipuBankV3 es un contrato bancario on‑chain que acepta depósitos en cualquier token (ERC‑20 o ETH), los convierte automáticamente a USDC mediante el Universal Router de Uniswap y mantiene el saldo interno de usuarios en USDC.
- Se añadieron controles básicos de capital: límite por banco (s_bankCapital) y límite global de depósitos (s_depositLimit).
- Seguridad: Ownable para administración y ReentrancyGuard para mitigar reentradas.

Mejoras realizadas y justificación
- Integración con Universal Router (Uniswap) para permitir swaps on‑the‑fly desde cualquier token hacia USDC. Justificación: reduce fricción para usuarios que no poseen USDC.
- Uso de Permit2 (aprobación previa) y SafeERC20 para transferencias más seguras. Justificación: manejo estándar de tokens y compatibilidad con el flujo de Universal Router.
- Ámbitos de seguridad mínimos: reentrancy guard, límites de capital y validaciones de saldo para retiros. Justificación: evitar ataques triviales y controlar exposición del contrato.
- Registro de eventos para depósitos, retiros y swaps. Justificación: auditoría y seguimiento en logs.

Instrucciones de despliegue (ejemplo con Hardhat)
1. Preparar entorno (en la carpeta del proyecto):
   - Instalar dependencias:
     - `npm install` (o `pnpm`/`yarn` según tu preferencia)
     - Asegúrate de tener los paquetes usados en los imports (openzepplin, uniswap universal-router, permit2, etc.)
2. Configurar `.env` con claves de despliegue (RPC URL de la testnet y PRIVATE_KEY).
3. Ejemplo de script de despliegue (Hardhat):
   - compile: `npx hardhat compile`
   - deploy: `npx hardhat run --network <testnet> scripts/deploy.js`
   - Verificar en el explorador: `npx hardhat verify --network <testnet> <DEPLOYED_ADDRESS> <constructorArg1> <constructorArg2> ...`
4. Interacción:
   - Depositar:
     - Llamar `depositArbitraryToken(tokenAddress, amount)` desde tu dapp / script. Si depositas ETH usar `tokenAddress = address(0)` y enviar `value = amount`.
   - Consultas:
     - `viewBalance(address)` para ver saldo en USDC.
     - `getContractBalance()` para ver USDC disponible en contrato.
   - Retirar:
     - `withdraw(amount)` para retirar USDC.
5. Nota práctica:
   - Antes de swap, el usuario debe aprobar (o usar Permit2) para que el Universal Router pueda mover tokens desde su wallet.
   - Si depositas ETH nativo, el contrato envuelve a WETH internamente.

Notas de diseño y trade‑offs importantes
- Contabilidad en USDC:
  - Ventaja: estabilidad y coherencia en la unidad de cuenta.
  - Trade‑off: dependencia en un token centralizado (USDC) y riesgos de slippage en swaps.
- Uso del Universal Router:
  - Ventaja: flexibilidad para rutas y diferentes versiones de pools.
  - Riesgo: requiere manejo correcto de comandos/paths; si las constantes de Commands cambian entre versiones puede romperse (ver warnings sobre Commands.*).
- Slippage y seguridad del swap:
  - Actualmente amountOutMinimum = 0 en swaps (sin protección de slippage). Esto es inseguro en producción — se debe añadir slippage tolerable o oráculos de precio.
- Approve a Permit2:
  - El contrato actualmente usa `IERC20(token).approve(i_permit2, amount)`; idealmente usar flujos seguros de Permit2 o approvals limitadas para minimizar riesgo de allowances maliciosas.
- Gas y complejidad:
  - Usar Universal Router y envolver ETH suma complejidad y gas; trade‑off entre UX (aceptar cualquier token) y coste por operación.
- Limitaciones conocidas:
  - No hay pausabilidad ni administración avanzada (emergencies).
  - No hay gestión de comisiones ni rendimiento para depositantes.
  - No validaciones adicionales sobre tokens recibidos (por ejemplo tokens con fees on transfer).

Dirección del contrato desplegado (testnet)
- Dirección desplegada: <REEMPLAZAR_POR_DIRECCION_REAL>
- Explorador y verificación: <REEMPLAZAR_POR_URL_DEL_EXPLORADOR_CON_FUENTE_VERIFICADA>

Por favor reemplaza las líneas anteriores con la dirección real del contrato y el enlace al explorador (Etherscan/Blockscout/Arbiscan/etc.) después de desplegar y verificar el código fuente.

