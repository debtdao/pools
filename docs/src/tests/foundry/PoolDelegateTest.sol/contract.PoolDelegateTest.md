# PoolDelegateTest
[Git Source](https://github.com/debtdao/pools/blob/3a355b63a4ea85c599cae3d82f5863faaeacb6a5/tests/foundry/PoolDelegateTest.sol)

**Inherits:**
Test, [Events](/tests/foundry/PoolDelegateTest.sol/contract.Events.md)


## State Variables
### POOL_NAME

```solidity
string constant POOL_NAME = "Test Pool";
```


### POOL_SYMBOL

```solidity
string constant POOL_SYMBOL = "TP";
```


### vyperDeployer

```solidity
VyperDeployer vyperDeployer = new VyperDeployer();
```


### lineFactory

```solidity
LineFactory lineFactory;
```


### moduleFactory

```solidity
ModuleFactory moduleFactory;
```


### oracle

```solidity
SimpleOracle oracle;
```


### line

```solidity
SecuredLine line;
```


### nonPoolLine

```solidity
SecuredLine nonPoolLine;
```


### iTokenA

```solidity
IBondToken iTokenA;
```


### iTokenB

```solidity
IBondToken iTokenB;
```


### pool

```solidity
IDebtDAOPool pool;
```


### fees

```solidity
Fees fees;
```


### delegate

```solidity
address delegate;
```


### arbiter

```solidity
address arbiter;
```


### borrower

```solidity
address borrower;
```


### swapTarget

```solidity
address swapTarget;
```


### userA

```solidity
address userA;
```


### userB

```solidity
address userB;
```


### ttl

```solidity
uint256 ttl = 180 days;
```


## Functions
### setUp


```solidity
function setUp() public;
```

### test_can_deploy_pool


```solidity
function test_can_deploy_pool() public;
```

### test_cannot_deposit_less_than_min_assets


```solidity
function test_cannot_deposit_less_than_min_assets() public;
```

### test_cannot_deposit_more_than_max_assets


```solidity
function test_cannot_deposit_more_than_max_assets() public;
```

### test_cannot_deposit_with_empty_recipient


```solidity
function test_cannot_deposit_with_empty_recipient() public;
```

### test_can_deposit_into_pool


```solidity
function test_can_deposit_into_pool() public;
```

### test_cannot_add_credit_as_non_delegate


```solidity
function test_cannot_add_credit_as_non_delegate() external;
```

### test_can_add_credit_and_increase_credit


```solidity
function test_can_add_credit_and_increase_credit() public;
```

### test_non_pool_line


```solidity
function test_non_pool_line() public;
```

### test_can_set_rates


```solidity
function test_can_set_rates() public;
```

### _usersDepositIntoPool


```solidity
function _usersDepositIntoPool() internal;
```

### _deployLine


```solidity
function _deployLine() internal;
```

### _deployPool


```solidity
function _deployPool() internal;
```

### _addCredit


```solidity
function _addCredit() internal returns (bytes32 id);
```

