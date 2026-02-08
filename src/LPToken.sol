// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LPToken – ERC-20 liquidity provider share token.
/// @notice Only the BinaryPMAMM (set at construction) can mint and burn.
contract LPToken is ERC20 {
    address public immutable amm;

    error OnlyAMM();

    modifier onlyAMM() {
        if (msg.sender != amm) revert OnlyAMM();
        _;
    }

    constructor(address _amm) ERC20("PM-AMM LP Share", "pmLP") {
        amm = _amm;
    }

    function mint(address to, uint256 amount) external onlyAMM {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyAMM {
        _burn(from, amount);
    }
}
