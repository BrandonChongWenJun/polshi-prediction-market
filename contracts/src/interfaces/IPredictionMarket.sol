// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/// @title IPredictionMarket
/// @notice Minimal view/resolution surface of {PredictionMarket} used by the {OrderBook} (secondary market)
///         and the {ReputationOracle} (reputation-weighted arbitrator).
interface IPredictionMarket is IERC1155 {
    /// @notice Core, fixed-size information about a market.
    /// @dev `numOutcomes == 0` means the market does not exist.
    struct MarketCore {
        address collateral;
        address arbitrator;
        uint64 closeTime;
        uint64 resolutionTime;
        uint8 numOutcomes;
        bool resolved;
        uint8 outcome;
    }

    /// @notice Sentinel outcome index meaning "invalid / cancelled" (every share redeems 1/N).
    function INVALID_OUTCOME() external view returns (uint8);

    /// @notice Time after `resolutionTime` during which the arbitrator may report.
    function ARBITRATION_TIMEOUT() external view returns (uint256);

    /// @notice Returns the core parameters and resolution state of `marketId`.
    function getMarketCore(uint256 marketId) external view returns (MarketCore memory);

    /// @notice ERC1155 token id of outcome `outcome` in market `marketId`.
    function positionId(uint256 marketId, uint8 outcome) external pure returns (uint256);

    /// @notice Called by the market's arbitrator to report the final outcome (or INVALID_OUTCOME).
    function reportOutcome(uint256 marketId, uint8 outcome) external;

    /// @notice Resolves an unreported market as invalid once the arbitration window has elapsed.
    function resolveAfterTimeout(uint256 marketId) external;
}
