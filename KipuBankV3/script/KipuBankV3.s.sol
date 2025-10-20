// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {KipuBankV3} from "../src/KipuBankV3.sol"; // Ajusta la ruta si es necesario

/**
 * @title KipuBankV3Deployment
 * @notice Script de Foundry para desplegar el contrato KipuBankV3 en una red EVM.
 */
contract KipuBankV3Deployment is Script {

    // --- Parámetros de Configuración del Despliegue ---
    
    // NOTA: Reemplaza estas direcciones con las de la red a la que vas a desplegar (ej. Sepolia, Mainnet).
    
    // 1. Límite de Capital: 100,000 USDC (asumiendo 6 decimales)
    uint256 private constant BANK_CAPITAL = 100000 * 10**6; 
    
    // 2. Límite Global de Depósito: 10,000 USDC
    uint256 private constant DEPOSIT_LIMIT_USDC = 10000 * 10**6;
    
    // 3. Direcciones de Contratos Uniswap y USDC (EJEMPLOS DE MAINNET/SEPOLIA)
    address private constant UNIVERSAL_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b; // Placeholder/Mainnet
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // Placeholder/Mainnet
    address private constant USDC_ADDRESS = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8; // Placeholder/Mainnet USDC (6 Decimals)

    function run() external {
        // La dirección del propietario será la cuenta que despliega el contrato.
        address deployer = msg.sender;

        // Inicia el proceso de transacción en la cadena (broadcasting).
        // vm.env("PRIVATE_KEY") lee la clave privada de tu archivo .env
        vm.startBroadcast();

        KipuBankV3 kipuBank = new KipuBankV3(
            BANK_CAPITAL,
            DEPOSIT_LIMIT_USDC,
            UNIVERSAL_ROUTER,
            PERMIT2,
            USDC_ADDRESS,
            deployer // El deployer es el dueño del contrato
        );

        vm.stopBroadcast();

        
    }
}