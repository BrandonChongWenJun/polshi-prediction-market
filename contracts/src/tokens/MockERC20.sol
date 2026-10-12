// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Standard OpenZeppelin ERC20 with configurable decimals and a public faucet (demo / testnet only),
///         used as the "DAI" stablecoin collateral (18 decimals).
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;
    uint256 public immutable faucetAmount;

    /// @param name_ Token name.
    /// @param symbol_ Token symbol.
    /// @param decimals_ Token decimals.
    /// @param faucetAmount_ Amount minted per {faucet} call, in base units.
    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 faucetAmount_)
        ERC20(name_, symbol_)
    {
        _decimals = decimals_;
        faucetAmount = faucetAmount_;
    }

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Mints `faucetAmount` to the caller.
    function faucet() external {
        _mint(msg.sender, faucetAmount);
    }

    /// @notice Mints `value` to `to` (demo / testnet only).
    function mint(address to, uint256 value) external {
        _mint(to, value);
    }
}
