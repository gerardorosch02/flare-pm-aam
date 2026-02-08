// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title IAnchorOracle – interface every oracle adapter must satisfy.
interface IAnchorOracle {
    function anchorPrice() external view returns (uint256);
}

/// @title StubAnchorOracle – simple owner-settable oracle for testing / bootstrapping.
contract StubAnchorOracle is IAnchorOracle, Ownable {
    uint256 private _anchorPrice;

    constructor() Ownable(msg.sender) {}

    /// @notice Owner can update the anchor price at any time.
    function setAnchorPrice(uint256 price) external onlyOwner {
        _anchorPrice = price;
    }

    /// @inheritdoc IAnchorOracle
    function anchorPrice() external view override returns (uint256) {
        return _anchorPrice;
    }
}
