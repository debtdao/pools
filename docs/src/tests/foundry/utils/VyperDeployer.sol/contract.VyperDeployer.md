# VyperDeployer
[Git Source](https://github.com/debtdao/pools/blob/3a355b63a4ea85c599cae3d82f5863faaeacb6a5/tests/foundry/utils/VyperDeployer.sol)


## State Variables
### HEVM_ADDRESS

```solidity
address constant HEVM_ADDRESS = address(bytes20(uint160(uint256(keccak256("hevm cheat code")))));
```


### cheatCodes
Initializes cheat codes in order to use ffi to compile Vyper contracts


```solidity
_CheatCodes cheatCodes = _CheatCodes(HEVM_ADDRESS);
```


## Functions
### deployContract

Compiles a Vyper contract and returns the address that the contract was deployeod to

If deployment fails, an error will be thrown


```solidity
function deployContract(string memory fileName) public returns (address);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`fileName`|`string`|- The file name of the Vyper contract. For example, the file name for "SimpleStore.vy" is "SimpleStore"|

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|deployedAddress - The address that the contract was deployed to|


### deployContract

create a list of strings with the commands necessary to compile Vyper contracts

compile the Vyper contract and return the bytecode

deploy the bytecode with the create instruction

check that the deployment was successful

return the address that the contract was deployed to

Compiles a Vyper contract with constructor arguments and returns the address that the contract was deployeod to

If deployment fails, an error will be thrown


```solidity
function deployContract(string memory fileName, bytes calldata args) public returns (address);
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`fileName`|`string`|- The file name of the Vyper contract. For example, the file name for "SimpleStore.vy" is "SimpleStore"|
|`args`|`bytes`||

**Returns**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`|deployedAddress - The address that the contract was deployed to|


