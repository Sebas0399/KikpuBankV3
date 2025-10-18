// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/Uniswap/universal-router/blob/main/contracts/interfaces/IUniversalRouter.sol";
import "https://github.com/Uniswap/universal-router/blob/main/contracts/libraries/Commands.sol";
import "https://github.com/Uniswap/permit2/blob/main/src/interfaces/IPermit2.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/IERC20.sol";
// Tipos V4 Core
import "https://github.com/Uniswap/v4-core/blob/main/src/types/PoolKey.sol";
import "https://github.com/Uniswap/v4-core/blob/main/src/types/Currency.sol";

// Acciones de V4
import "https://github.com/Uniswap/v4-periphery/blob/main/src/libraries/Actions.sol";

/**
 * @title Banco Kipu (KipuBankV2)
 * @author Antony Arguello
 * @notice Contrato bancario descentralizado que permite depósitos y retiros en ETH y USDC.
 *         Utiliza Chainlink como oráculo de precios y controla límites globales y de capital.
 * @dev Implementa seguridad contra reentradas y permisos de propietario.
 */
contract KipuBankV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // ░░░ VARIABLES DE ESTADO ░░░
    // -----------------------------------------------------------------------

    /// @notice Bóveda: mapea usuario => token => cantidad.
    mapping(address user => mapping(address token => uint256 amount))
        public s_vault;

    /// @notice Oráculo de precios (por ejemplo, ETH/USD de Chainlink).
    AggregatorV3Interface public s_oracle;
    IUniversalRouter public s_router;
    IPermit2 public s_permit2;
    IERC20 public s_weth;

    /// @notice Tiempo máximo permitido sin actualización del oráculo (1 hora).
    uint256 constant ORACLE_HEARTBEAT = 3600;

    /// @notice Factor de conversión entre ETH (wei), precio (1e8) y USDC (1e6).
    uint256 constant DECIMAL_FACTOR = 1 * 10 ** 20;

    /// @notice Token USDC usado por el contrato.
    IERC20 public immutable i_usdc;

    /// @notice Límite global de depósitos (en unidades USDC, 6 decimales).
    uint256 public s_depositLimit;

    /// @notice Total acumulado de depósitos (en USDC-units).
    uint256 public s_totalDeposits;

    /// @notice Capital máximo permitido en el banco.
    uint256 public s_bankCapital;

    /// @notice Límite máximo de retiro en ETH.
    uint256 private constant WITHDRAW_LIMIT = 0.01 ether;

    /// @notice Contadores de operaciones.
    uint256 public s_withdrawCount;
    uint256 public s_depositCount;

    // -----------------------------------------------------------------------
    // ░░░ EVENTOS ░░░
    // -----------------------------------------------------------------------

    event SuccessfulWithdrawal(address user, uint256 amount);
    event SuccessfulDeposit(address user, address currency, uint256 amount);
    event OracleUpdated(address newOracle);
    event SwapExecuted(
        address indexed from,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut
    );

    // -----------------------------------------------------------------------
    // ░░░ ERRORES PERSONALIZADOS ░░░
    // -----------------------------------------------------------------------

    error MoneyLimit(uint256 amount, address user, string detail);
    error InsufficientBalance(uint256 amount, address user, string detail);
    error GlobalLimit(uint256 amount, string detail);
    error OracleCompromised();
    error OracleOutdated();
    error BankLimitReached(uint256 bankLimit);
    error WithdrawalFailed();

    // -----------------------------------------------------------------------
    // ░░░ MODIFICADORES ░░░
    // -----------------------------------------------------------------------

    /**
     * @dev Verifica que el monto no exceda el límite global de depósitos.
     * @param _usdcAmount Monto en unidades USDC.
     */
    modifier withinGlobalLimit(uint256 _usdcAmount) {
        if (_exceedsDepositLimit(_usdcAmount)) {
            revert GlobalLimit(_usdcAmount, "Global limit reached");
        }
        _;
    }

    /**
     * @dev Verifica que el monto no exceda el capital total permitido del banco.
     * @param _usdcAmount Monto en unidades USDC.
     */
    modifier withinBankCapital(uint256 _usdcAmount) {
        if (s_totalDeposits + _usdcAmount > s_bankCapital) {
            revert BankLimitReached(s_bankCapital);
        }
        _;
    }

    /**
     * @dev Verifica que el monto de retiro sea válido y que el usuario tenga saldo suficiente.
     * @param _amount Monto a retirar (en wei).
     */
    modifier validWithdrawal(uint256 _amount) {
        if (_amount > WITHDRAW_LIMIT) {
            revert MoneyLimit(
                _amount,
                msg.sender,
                "Cannot withdraw more than 0.01 ETH"
            );
        } else if (s_vault[msg.sender][address(0)] < _amount) {
            revert InsufficientBalance(
                _amount,
                msg.sender,
                "Insufficient balance"
            );
        }
        _;
    }

    // -----------------------------------------------------------------------
    // ░░░ CONSTRUCTOR ░░░
    // -----------------------------------------------------------------------

    /**
     * @param _bankCapital Límite máximo de capital del banco (en USDC-units).
     * @param _depositLimitUSDC Límite global de depósitos (en USDC-units).
     * @param _oracle Dirección del oráculo de Chainlink (ETH/USD).
     * @param _usdc Dirección del contrato del token USDC.
     * @param _owner Dirección del propietario del contrato.
     */
    constructor(
        uint256 _bankCapital,
        uint256 _depositLimitUSDC,
        address _oracle,
        address _router,
        address _permit2,
        address _usdc,
        address _owner
    ) Ownable(_owner) {
        s_oracle = AggregatorV3Interface(_oracle);
        i_usdc = IERC20(_usdc);
        s_bankCapital = _bankCapital;
        s_depositLimit = _depositLimitUSDC;
        s_router = IUniversalRouter(_router);
        s_permit2 = IPermit2(_permit2);
    }

    // -----------------------------------------------------------------------
    // ░░░ FUNCIONES INTERNAS ░░░
    // -----------------------------------------------------------------------
    function swapToUSDC(
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin,
        PoolKey memory poolKey
    ) external {
        require(amountIn > 0, "amountIn = 0");
        require(tokenIn != address(i_usdc), "tokenIn = USDC");

        // 1️⃣ Transferir tokens de entrada desde el usuario al contrato
        IERC20 inputToken = IERC20(tokenIn);
        inputToken.transferFrom(msg.sender, address(this), amountIn);
        s_permit2.approve(
            tokenIn,
            address(s_router),
            type(uint160).max,
            type(uint48).max
        );

        // 3️⃣ Definir acciones para el Universal Router
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
            bytes1(uint8(Actions.TAKE_ALL)),
            bytes1(uint8(Actions.SETTLE_ALL))
        );

        // 4️⃣ Codificar parámetros para el Universal Router
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            poolKey,
            tokenIn < address(i_usdc),
            amountIn,
            amountOutMin,
            bytes("")
        );
        Currency usdcCurrency = Currency(address(i_usdc)); // ✅ Hypothetical example

        params[1] = abi.encode(usdcCurrency); // ✅ Fixed: No named args
        params[2] = abi.encode(usdcCurrency); // ✅ Fixed: No named args

        s_router.execute(actions, params, block.timestamp);

        // 6️⃣ Transferir los USDC al usuario
        uint256 outBalance = i_usdc.balanceOf(address(this));
        require(outBalance >= amountOutMin, "Insufficient USDC out");
        i_usdc.safeTransfer(msg.sender, outBalance);

        emit SwapExecuted(msg.sender, tokenIn, amountIn, outBalance);
    }
    /**
     * @notice Obtiene el precio ETH/USD desde el oráculo Chainlink.
     * @return ethUSDPrice Precio de ETH en USD con 8 decimales.
     */
    function _getETHUSDPrice() internal view returns (uint256 ethUSDPrice) {
        (, int256 price, , uint256 updatedAt, ) = s_oracle.latestRoundData();

        if (price == 0) revert OracleCompromised();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT)
            revert OracleOutdated();

        ethUSDPrice = uint256(price);
    }

    /**
     * @notice Convierte una cantidad en ETH a su equivalente en USDC.
     * @param _ethAmount Cantidad en wei.
     * @return convertedAmount Equivalente en USDC (6 decimales).
     */
    function _convertETHtoUSDC(
        uint256 _ethAmount
    ) internal view returns (uint256 convertedAmount) {
        convertedAmount = (_ethAmount * _getETHUSDPrice()) / DECIMAL_FACTOR;
    }

    /**
     * @notice Verifica si se excede el límite global de depósitos.
     * @param amountUSDC Monto en unidades USDC.
     */
    function _exceedsDepositLimit(
        uint256 amountUSDC
    ) private view returns (bool) {
        return (s_totalDeposits + amountUSDC) > s_depositLimit;
    }

    // -----------------------------------------------------------------------
    // ░░░ FUNCIONES DE CONSULTA ░░░
    // -----------------------------------------------------------------------

    /**
     * @notice Retorna el balance total del contrato en unidades USDC.
     */
    function contractBalanceInUSDC()
        public
        view
        returns (uint256 totalBalance)
    {
        uint256 ethInUSDC = _convertETHtoUSDC(address(this).balance);
        uint256 usdcBalance = i_usdc.balanceOf(address(this));
        totalBalance = ethInUSDC + usdcBalance;
    }

    /**
     * @notice Retorna el saldo del usuario en ETH convertido a USDC.
     */
    function viewETHBalance(address user) external view returns (uint256) {
        return _convertETHtoUSDC(s_vault[user][address(0)]);
    }

    /**
     * @notice Retorna el saldo del usuario en USDC.
     */
    function viewUSDCBalance(address user) external view returns (uint256) {
        return s_vault[user][address(i_usdc)];
    }

    // -----------------------------------------------------------------------
    // ░░░ FUNCIONES DE USUARIO ░░░
    // -----------------------------------------------------------------------

    /**
     * @notice Permite al usuario retirar ETH de su bóveda.
     * @param _withdrawAmount Cantidad a retirar en wei.
     */
    function withdrawETH(
        uint256 _withdrawAmount
    ) external nonReentrant validWithdrawal(_withdrawAmount) {
        s_vault[msg.sender][address(0)] -= _withdrawAmount;
        s_withdrawCount++;

        (bool success, ) = payable(msg.sender).call{value: _withdrawAmount}("");
        require(success, "Withdrawal failed");

        emit SuccessfulWithdrawal(msg.sender, _withdrawAmount);
    }

    /**
     * @notice Permite depositar ETH en la bóveda personal.
     */
    function depositETH()
        external
        payable
        nonReentrant
        withinGlobalLimit(_convertETHtoUSDC(msg.value))
        withinBankCapital(_convertETHtoUSDC(msg.value))
    {
        require(msg.value > 0, "Zero deposit");

        uint256 usdAmount = _convertETHtoUSDC(msg.value);
        s_depositCount++;
        s_totalDeposits += usdAmount;
        s_vault[msg.sender][address(0)] += msg.value;

        emit SuccessfulDeposit(msg.sender, address(0), msg.value);
    }

    /**
     * @notice Permite depositar USDC directamente.
     * @param _usdcAmount Cantidad en unidades USDC (6 decimales).
     */
    function depositUSDC(
        uint256 _usdcAmount
    )
        external
        nonReentrant
        withinGlobalLimit(_usdcAmount)
        withinBankCapital(_usdcAmount)
    {
        require(_usdcAmount > 0, "Zero deposit");

        s_depositCount++;
        s_totalDeposits += _usdcAmount;
        s_vault[msg.sender][address(i_usdc)] += _usdcAmount;

        i_usdc.safeTransferFrom(msg.sender, address(this), _usdcAmount);

        emit SuccessfulDeposit(msg.sender, address(i_usdc), _usdcAmount);
    }

    /**
     * @notice Permite retirar USDC desde la bóveda personal.
     * @param _usdcAmount Cantidad en USDC (6 decimales).
     */
    function withdrawUSDC(uint256 _usdcAmount) external nonReentrant {
        if (s_vault[msg.sender][address(i_usdc)] < _usdcAmount) {
            revert InsufficientBalance(
                _usdcAmount,
                msg.sender,
                "Insufficient balance"
            );
        }

        s_vault[msg.sender][address(i_usdc)] -= _usdcAmount;
        s_withdrawCount++;

        i_usdc.safeTransfer(msg.sender, _usdcAmount);

        emit SuccessfulWithdrawal(msg.sender, _usdcAmount);
    }

    // -----------------------------------------------------------------------
    // ░░░ FUNCIONES ADMINISTRATIVAS ░░░
    // -----------------------------------------------------------------------

    /**
     * @notice Permite actualizar el oráculo de precios.
     * @param _newOracle Nueva dirección del oráculo Chainlink.
     */
    function setOracle(address _newOracle) external onlyOwner {
        s_oracle = AggregatorV3Interface(_newOracle);
        emit OracleUpdated(_newOracle);
    }

    /**
     * @notice Permite al propietario ajustar el capital máximo del banco.
     * @param _newCapital Límite en unidades USDC.
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
