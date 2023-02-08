# IDebtDAOPool
[Git Source](https://github.com/debtdao/pools/blob/3a355b63a4ea85c599cae3d82f5863faaeacb6a5/tests/foundry/interfaces/IDebtDAOPool.sol)


## Functions
### APR


```solidity
function APR() external view returns (int256);
```

### price


```solidity
function price() external view returns (uint256);
```

### owner


```solidity
function owner() external view returns (address);
```

### unlock_profits


```solidity
function unlock_profits() external returns (uint256);
```

### collect_interest


```solidity
function collect_interest(address line, bytes32 id) external returns (uint256);
```

### add_credit


```solidity
function add_credit(address line, uint128 drate, uint128 frate, uint256 amount) external returns (bytes32);
```

### increase_credit


```solidity
function increase_credit(address line, bytes32 id, uint256 amount) external returns (bool);
```

### set_rates


```solidity
function set_rates(address line, bytes32 id, uint128 drate, uint128 frate) external returns (bool);
```

### deposit


```solidity
function deposit(uint256 _assets, address _receiver) external returns (uint256);
```

### depositWithReferral


```solidity
function depositWithReferral(uint256 _assets, address _receiver, address _referrer) external returns (uint256);
```

### set_min_deposit


```solidity
function set_min_deposit(uint256 new_min) external returns (bool);
```

### set_max_assets


```solidity
function set_max_assets(uint256 new_max) external returns (bool);
```

