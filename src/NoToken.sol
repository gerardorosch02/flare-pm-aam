// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title NoToken – ERC-20 position token for NO outcome shares.
/// @notice Only the BinaryPMAMM (set at construction) can mint and burn.
///         Sellers do NOT need to approve the AMM — the AMM burns directly.
contract NoToken is ERC20 {
    address public immutable amm;

    error OnlyAMM();

    modifier onlyAMM() {
        if (msg.sender != amm) revert OnlyAMM();
        _;
    }

    constructor(address _amm) ERC20("PM-AMM NO Share", "pmNO") {
        amm = _amm;
    }

    function mint(address to, uint256 amount) external onlyAMM {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyAMM {
        _burn(from, amount);
    }
}
