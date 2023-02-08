# SimpleVyperTest
[Git Source](https://github.com/debtdao/pools/blob/3a355b63a4ea85c599cae3d82f5863faaeacb6a5/tests/foundry/SimpleVyperTest.sol)

**Inherits:**
Test


## State Variables
### vyperDeployer
create a new instance of VyperDeployer


```solidity
VyperDeployer vyperDeployer = new VyperDeployer();
```


### iToken

```solidity
IBondToken iToken;
```


### debtdao

```solidity
address debtdao = makeAddr("debtdao");
```


## Functions
### setUp


```solidity
function setUp() public;
```

### test_can_mint_as_manager

deploy a new instance of ISimplestore by passing in the address of the deployed Vyper contract


```solidity
function test_can_mint_as_manager() public;
```

