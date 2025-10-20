// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Importaciones del Universal Router (para Swaps V2/V3/Permit2)
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";

// Utilidades y Externos
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IWETH9} from "@uniswap/universal-router/contracts/interfaces/external/IWETH9.sol";

/**
 * @title Banco Kipu (KipuBankV3)
 * @author Antony Arguello
 * @notice Contrato bancario descentralizado que permite depósitos de cualquier token
 * y los convierte a USDC usando Universal Router para gestionar el capital.
 * @dev Implementa seguridad contra reentradas y permisos de propietario.
 * El capital interno se mantiene únicamente en unidades USDC.
 */
contract KipuBankV3 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // ░░░ CONSTANTES ░░░
    // -----------------------------------------------------------------------

    /// @notice Dirección de WETH9 en Mainnet (usada para envolver ETH entrante).
    address private constant WETH9_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    
    // -----------------------------------------------------------------------
    // ░░░ VARIABLES DE ESTADO ░░░
    // -----------------------------------------------------------------------

    /// @notice Bóveda de saldos: mapea usuario => cantidad (en USDC-units).
    mapping(address user => uint256 amount) public s_vault;

    /// @notice Interfaz del Universal Router (para ejecutar swaps).
    IUniversalRouter public immutable i_router;

    /// @notice Interfaz de Permit2 (para autorizar tokens antes del swap).
    IPermit2 public immutable i_permit2;

    /// @notice Token USDC usado por el contrato (la moneda base del banco).
    IERC20 public immutable i_usdc;

    /// @notice Límite global de depósitos (en unidades USDC, 6 decimales).
    uint256 public s_depositLimit;

    /// @notice Total acumulado de depósitos (en USDC-units) en la bóveda de usuarios.
    uint256 public s_totalDeposits;

    /// @notice Capital máximo permitido en el banco (Bank Cap).
    uint256 public s_bankCapital;

    /// @notice Contadores de operaciones.
    uint256 public s_withdrawCount;
    uint256 public s_depositCount;

    // -----------------------------------------------------------------------
    // ░░░ EVENTOS ░░░
    // -----------------------------------------------------------------------

    event SuccessfulWithdrawal(address user, uint256 amount);
    event SuccessfulDeposit(address user, address tokenIn, uint256 usdcAmountReceived);
    event SwapExecuted(
        address indexed from,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut
    );

    // -----------------------------------------------------------------------
    // ░░░ ERRORES PERSONALIZADOS ░░░
    // -----------------------------------------------------------------------

    error BankLimitReached(uint256 bankLimit, uint256 totalDeposits, uint256 incomingAmount);
    error GlobalLimit(uint256 amount, string detail);
    error InsufficientBalance(uint256 amount, address user, string detail);

    // -----------------------------------------------------------------------
    // ░░░ CONSTRUCTOR ░░░
    // -----------------------------------------------------------------------

    /**
     * @param _bankCapital Límite máximo de capital del banco (en unidades USDC, 6 decimales).
     * @param _depositLimitUSDC Límite global de depósitos por usuario (en unidades USDC).
     * @param _router Dirección del Universal Router.
     * @param _permit2 Dirección del contrato Permit2.
     * @param _usdc Dirección del contrato del token USDC.
     * @param _owner Dirección del propietario del contrato.
     */
    constructor(
        uint256 _bankCapital,
        uint256 _depositLimitUSDC,
        address _router,
        address _permit2,
        address _usdc,
        address _owner
    ) Ownable(_owner) {
        i_usdc = IERC20(_usdc);
        s_bankCapital = _bankCapital;
        s_depositLimit = _depositLimitUSDC;
        i_router = IUniversalRouter(_router);
        i_permit2 = IPermit2(_permit2);
    }

    // -----------------------------------------------------------------------
    // ░░░ FUNCIONES INTERNAS DE UTILIDAD ░░░
    // -----------------------------------------------------------------------

    /**
     * @notice Convierte el token entrante (ETH o ERC-20) a USDC usando Universal Router.
     * @param tokenIn Dirección del token entrante (address(0) para ETH).
     * @param amountIn Cantidad del token entrante.
     * @param payer Dirección de quien paga (msg.sender).
     * @return amountOut Cantidad de USDC recibida después del swap.
     */
    function _swapToUSDC(
        address tokenIn,
        uint256 amountIn,
        address payer
    ) internal returns (uint256 amountOut) {
        // Si el token es directamente USDC, no se realiza swap.
        if (tokenIn == address(i_usdc)) {
            i_usdc.safeTransferFrom(payer, address(this), amountIn);
            return amountIn;
        }

        // Si es ETH nativo (address(0)), se envuelve a WETH.
        if (tokenIn == address(0)) {
            IWETH9(WETH9_ADDRESS).deposit{value: amountIn}();
            tokenIn = WETH9_ADDRESS;
        } else {
            // Transferir el ERC20 al contrato (si no es ETH/WETH).
            IERC20(tokenIn).safeTransferFrom(payer, address(this), amountIn);
        }
        
        // El Universal Router requiere aprobación a Permit2 para tokens ERC20.
        // Se aprueba el tokenIn (que ahora es WETH o el ERC20 original) al Permit2.
        IERC20(tokenIn).approve(address(i_permit2), amountIn);

        // --- Configuración del Swap a través de Universal Router ---
        
        // Comando: V3_SWAP_EXACT_IN (Swapear una cantidad exacta del tokenIn)
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.V3_SWAP_EXACT_IN))
        );
        
        // Input: [recipient, amountIn, amountOutMinimum, path, payerIsUser]
        // El path es tokenIn -> Fee (3000 = 0.3%) -> USDC
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(this), // recipient: el propio contrato del banco
            amountIn,
            0, // amountOutMinimum: No se usa slippage en este ejemplo, asume 0
            abi.encodePacked(tokenIn, uint24(3000), address(i_usdc)), // path (WETH/ERC20 -> USDC)
            true // payerIsUser: true, Universal Router gestionará la transferencia/Permit2
        );

        uint256 usdcBefore = i_usdc.balanceOf(address(this));
        
        // Ejecutar el swap.
        i_router.execute(commands, inputs, block.timestamp + 300);
        
        uint256 usdcAfter = i_usdc.balanceOf(address(this));

        amountOut = usdcAfter - usdcBefore;

        emit SwapExecuted(payer, tokenIn, amountIn, amountOut);
        return amountOut;
    }

    // -----------------------------------------------------------------------
    // ░░░ FUNCIONES DE CONSULTA ░░░
    // -----------------------------------------------------------------------

    /**
     * @notice Retorna el balance total del contrato en unidades USDC.
     */
    function getContractBalance() public view returns (uint256 totalBalance) {
        totalBalance = i_usdc.balanceOf(address(this));
    }
    
    /**
     * @notice Retorna el saldo del usuario en la bóveda (unidades USDC).
     */
    function viewBalance(address user) external view returns (uint256) {
        return s_vault[user];
    }
    /**
     * @notice Permite al usuario depositar cualquier token. El token se convierte a USDC
     * y se añade al saldo del usuario, respetando los límites de capital.
     * @param tokenAddress Dirección del token a depositar (address(0) para ETH).
     * @param amount Cantidad del token a depositar.
     */
    function depositArbitraryToken(address tokenAddress, uint256 amount) external nonReentrant {
        _swapExactInputSingle(tokenAddress, amount);
    }
    // -----------------------------------------------------------------------
    // ░░░ FUNCIONES DE USUARIO ░░░
    // -----------------------------------------------------------------------

    /**
     * @notice Permite al usuario depositar cualquier token. El token se convierte a USDC
     * y se añade al saldo del usuario, respetando los límites de capital.
     * @param tokenAddress Dirección del token a depositar (address(0) para ETH).
     * @param amount Cantidad del token a depositar.
     */
    function _swapExactInputSingle(
        address tokenAddress,
        uint256 amount
    ) internal  nonReentrant {
        // 1. Ejecutar swap y obtener el monto final en USDC
        uint256 usdcReceived = _swapToUSDC(tokenAddress, amount, msg.sender);

        // 2. Verificar límites de capital y globales con el monto USDC recibido
        
        // A. Verificar Límite de Capital (Bank Cap)
        if (s_totalDeposits + usdcReceived > s_bankCapital) {
            revert BankLimitReached(
                s_bankCapital,
                s_totalDeposits,
                usdcReceived
            );
        }
        
        // B. Verificar Límite Global de Depósito
        if (s_totalDeposits + usdcReceived > s_depositLimit) {
            revert GlobalLimit(usdcReceived, "Global deposit limit reached");
        }

        // 3. Actualizar el estado
        s_depositCount++;
        s_totalDeposits += usdcReceived;
        s_vault[msg.sender] += usdcReceived;

        emit SuccessfulDeposit(msg.sender, tokenAddress, usdcReceived);
    }

    /**
     * @notice Permite al usuario retirar su saldo en USDC.
     * @param amount Cantidad de USDC a retirar.
     */
    function withdraw(uint256 amount) external nonReentrant {
        // Verificar saldo suficiente.
        if (s_vault[msg.sender] < amount) {
            revert InsufficientBalance(
                amount,
                msg.sender,
                "Insufficient balance in USDC"
            );
        }

        // Actualizar el estado del banco
        s_withdrawCount++;
        s_vault[msg.sender] -= amount;

        // Transferir USDC al usuario
        i_usdc.safeTransfer(msg.sender, amount);
        
        // Reducir el total de depósitos del banco
        s_totalDeposits -= amount;

        emit SuccessfulWithdrawal(msg.sender, amount);
    }

    // -----------------------------------------------------------------------
    // ░░░ FUNCIONES DE ADMINISTRACIÓN (OnlyOwner) ░░░
    // -----------------------------------------------------------------------

    /**
     * @notice Permite al propietario ajustar el capital máximo del banco.
     * @param _newCapital Nuevo límite en unidades USDC.
     */
    function setBankCapital(uint256 _newCapital) external onlyOwner {
        s_bankCapital = _newCapital;
    }

    /**
     * @notice Permite al propietario ajustar el límite global de depósitos.
     * @param _newLimit Nuevo límite en unidades USDC.
     */
    function setDepositLimit(uint256 _newLimit) external onlyOwner {
        s_depositLimit = _newLimit;
    }
}
