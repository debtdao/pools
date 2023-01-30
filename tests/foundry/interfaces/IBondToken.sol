// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;


interface IBondToken {
    function _mint_for_testing(address _target, uint256 _value)
        external
        returns (bool);

    function balanceOf(address _owner) external view returns (uint256);

    function name() external view returns (string memory);

    function decimals() external view returns (uint256);
}