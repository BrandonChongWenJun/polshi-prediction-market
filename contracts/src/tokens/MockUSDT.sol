// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title MockUSDT
/// @notice Test/demo stand-in for Tether USD that reproduces its non-standard ERC20 behaviour:
///         6 decimals, `transfer`/`transferFrom`/`approve` return NO value, and `approve` from a non-zero
///         allowance to another non-zero allowance reverts. The protocol must therefore use SafeERC20.
/// @dev Anyone can call {faucet} (demo / testnet only). An infinite allowance is never decreased (like USDT).
contract MockUSDT {
    string public constant name = "Tether USD (Mock)";
    string public constant symbol = "USDT";
    uint8 public constant decimals = 6;
    uint256 public constant FAUCET_AMOUNT = 10_000 * 1e6;

    uint256 public totalSupply;
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();
    error InsufficientAllowance();
    error ApproveFromNonZero();
    error ZeroAddress();

    /// @notice Transfers `value` to `to`. Returns nothing, like USDT.
    function transfer(address to, uint256 value) external {
        _transfer(msg.sender, to, value);
    }

    /// @notice Transfers `value` from `from` to `to` using the caller's allowance. Returns nothing, like USDT.
    function transferFrom(address from, address to, uint256 value) external {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < value) revert InsufficientAllowance();
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _transfer(from, to, value);
    }

    /// @notice Sets the allowance. Reverts when changing a non-zero allowance to another non-zero value (USDT rule).
    function approve(address spender, uint256 value) external {
        if (value != 0 && allowance[msg.sender][spender] != 0) revert ApproveFromNonZero();
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
    }

    /// @notice Mints FAUCET_AMOUNT to the caller (demo / testnet faucet).
    function faucet() external {
        _mint(msg.sender, FAUCET_AMOUNT);
    }

    /// @notice Mints `value` to `to` (demo / testnet only; there is no real backing).
    function mint(address to, uint256 value) external {
        _mint(to, value);
    }

    function _mint(address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < value) revert InsufficientBalance();
        balanceOf[from] = bal - value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
