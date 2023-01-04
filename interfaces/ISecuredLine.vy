# @version ^0.3.7

interface ISecuredLine:
    def ids(index: uint256) -> bytes32: view
    def status() -> uint256: view
    def credits(id: bytes32) -> Position: view
    def available(id: bytes32) -> (uint256, uint256): view

    def addCredit(
        drate: uint128,
        frate: uint128,
        amount: uint256,
        token: address,
        lender: address
    )-> bytes32: payable
    def setRates(id: bytes32, drate: uint128, frate: uint128) -> bool: payable
    def increaseCredit(id: bytes32,  amount: uint256) -> bool: payable

    # self-repay
    def claimAndRepay(claimToken: address, tradeData: Bytes[50000]) -> uint256: payable
    def useAndRepay(amount: uint256) -> bool: payable

    # divest
    def withdraw(id: bytes32,  amount: uint256) -> bool: payable

    #arbiter
    def declareInsolvent() -> bool: payable
    def sweep(token: address, to: address) -> bool: payable
    def liquidate(amount: uint256, targetToken: address)-> uint256: payable
    def addSpigot(revenueContract: address, settings: Bytes[9])-> uint256: payable

# (uint256, uint256, uint256, uint256, uint8, address, address)
struct Position:
    deposit: uint256
    principal: uint256
    interestAccrued: uint256
    interestRepaid: uint256
    decimals: uint8
    token: address
    lender: address
