// SPDX-License-Identifier: MIT

pragma solidity >=0.8.7 <0.9.0;

/**
 * @dev Interface .
 */
interface IValidatorSet {
    function applyCandidate(
        address coinbase,
        uint256 commission,
        bytes32 name,
        uint256 selfStake
    ) external returns (uint256);
}
