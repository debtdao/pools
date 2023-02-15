// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

struct Fees {
    uint16 performance;
    uint16 deposit;
    uint16 withdraw;
    uint16 flash;
    uint16 collector;
    uint16 referral;
}

interface IDebtDAOPool {

    // getters
    function APR() external view returns (int256);
    function price() external view returns (uint256);
    function owner() external view returns (address);

    // investments
    function unlock_profits() external returns (uint256);
    function collect_interest(address line, bytes32 id) external returns (uint256);

    // credit
    function add_credit(address line, uint128 drate, uint128 frate, uint256 amount) external returns (bytes32);
    function increase_credit(address line, bytes32 id, uint256 amount) external;
    function reduce_credit(address _line, bytes32 _id, uint256 _amount) external returns(uint256, uint256);
    function use_and_repay(address _line, uint256 _repay, uint256 _withdraw) external returns(uint256, uint256);

    function set_rates( address line, bytes32 id, uint128 drate, uint128 frate) external;
    function deposit(uint256 _assets, address _receiver) external returns (uint256);
    function depositWithReferral(uint256 _assets, address _receiver, address _referrer) external returns (uint256);

    function impair(address _line, bytes32 _id) external returns (uint256,uint256);
    // abort
    function abort(address _line, bytes32 _id) external returns(uint256, uint256);
    // Pool Admin
    function set_min_deposit(uint256 new_min) external returns (bool);
    function set_max_assets(uint256 new_max) external returns (bool);
}
