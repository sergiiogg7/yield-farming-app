// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockToken
/// @notice ERC-20 used only in tests. The initial supply is minted to the deployer.
contract MockToken is ERC20, Ownable {
    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param initialSupply_ Whole-token amount minted to the deployer (scaled by decimals).
    constructor(string memory name_, string memory symbol_, uint256 initialSupply_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        _mint(msg.sender, initialSupply_ * 10 ** decimals());
    }

    /// @notice Mints `amount_` tokens to `to_`. Owner only.
    function mint(address to_, uint256 amount_) external onlyOwner {
        _mint(to_, amount_);
    }

    /// @notice Burns `amount_` tokens from the caller.
    function burn(uint256 amount_) external {
        _burn(msg.sender, amount_);
    }
}
