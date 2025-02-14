// // SPDX-License-Identifier: MIT
// pragma solidity ^0.6.6;

// interface MockV3AggregatorInterface {
//     function decimals() external view returns (uint8);
//     function description() external view returns (string memory);
//     function version() external view returns (uint256);
//     function getRoundData(uint80 _roundId)
//         external
//         view
//         returns (
//             uint80 roundId,
//             int256 answer,
//             uint256 startedAt,
//             uint256 updatedAt,
//             uint80 answeredInRound
//         );
//     function latestRoundData()
//         external
//         view
//         returns (
//             uint80 roundId,
//             int256 answer,
//             uint256 startedAt,
//             uint256 updatedAt,
//             uint80 answeredInRound
//         );
//     function updateAnswer(int256 _answer) external;
//     function updateRoundData(
//         uint80 _roundId,
//         int256 _answer,
//         uint256 _timestamp,
//         uint256 _startedAt
//     ) external;
// } 