// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockLPToken is ERC20 {
    address public immutable token0;
    address public immutable token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    constructor(
        address _token0,
        address _token1
    ) ERC20("Mock LP Token", "LP") {
        token0 = _token0;
        token1 = _token1;
        // Set more realistic reserves (1M tokens each with 18 decimals)
        reserve0 = uint112(1_000_000 * 10**18);
        reserve1 = uint112(1_000_000 * 10**18);
        blockTimestampLast = uint32(block.timestamp);
        // Mint a smaller amount of LP tokens (100K)
        _mint(msg.sender, 100_000 * 10**18);
    }

    function getReserves() external view returns (
        uint112 _reserve0, 
        uint112 _reserve1, 
        uint32 _blockTimestampLast
    ) {
        return (reserve0, reserve1, blockTimestampLast);
    }
} 