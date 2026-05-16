// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Pyth Network on-chain oracle
/// @dev Contract addresses: https://docs.pyth.network/price-feeds/contract-addresses
interface IPyth {
    struct Price {
        int64  price;       // Price scaled by 10^expo
        uint64 conf;        // Confidence interval
        int32  expo;        // Negative exponent (e.g. -8 means price is in units of 1e-8)
        uint   publishTime; // Unix timestamp of price
    }

    struct PriceFeed {
        bytes32 id;
        Price   price;
        Price   emaPrice;
    }

    /// @notice Get the current price for a feed. Reverts if price is stale.
    function getPrice(bytes32 id) external view returns (Price memory price);

    /// @notice Get the price, reverting if older than `age` seconds
    function getPriceNoOlderThan(bytes32 id, uint age) external view returns (Price memory price);

    /// @notice Push fresh price data on-chain (call before reading price on-chain)
    function updatePriceFeeds(bytes[] calldata updateData) external payable;

    /// @notice ETH fee required to call updatePriceFeeds
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint feeAmount);
}
