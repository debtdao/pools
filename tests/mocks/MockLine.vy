# @version ^0.3.7
from vyper.interfaces import ERC20 as IERC20

interface ISecuredLine:
    def borrower() -> address: pure
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
    isOpen: bool

struct Rate:
    drate: uint128
    frate: uint128
    last_accrued: uint256

# implements: ISecuredLine
BPS_COEFFICIENT: constant(uint256) = 10_000

ids: public(uint256)
status: public(uint256)
borrower: public(address)
credits: public(HashMap[bytes32, Position])
rates: public(HashMap[bytes32, Rate])


@external
def __init__(_borrower: address):
    self.status = 1
    self.borrower = _borrower

@external
def available(id: bytes32) -> (uint256, uint256): 
    return ((self.credits[id].deposit - self.credits[id].principal), self.credits[id].interestRepaid)

@external
def addCredit(
    _drate: uint128,
    _frate: uint128,
    _amount: uint256,
    _token: address,
    _lender: address,
) -> bytes32:
    id: bytes32 = keccak256(_abi_encode(self, _lender, _token))
    self._set_rates(id, _drate, _frate)
    self.credits[id] = Position({
        deposit: _amount,
        principal: 0,
        interestAccrued: 0,
        interestRepaid: 0,
        decimals: 18,
        token: _token,
        lender: _lender,
        isOpen: True,
    })

    IERC20(_token).transferFrom(_lender, self, _amount)
    
    return id


@internal
def _set_rates(id: bytes32, drate: uint128, frate: uint128): 
    self.rates[id] = Rate({ drate: drate, frate: frate, last_accrued: block.timestamp })

@external
def setRates(id: bytes32, drate: uint128, frate: uint128): 
    self._set_rates(id, drate, frate)

@external
def increaseCredit(id: bytes32,  amount: uint256): 
    self.credits[id].deposit += amount
    IERC20(self.credits[id].token).transferFrom(msg.sender, self, amount)

@pure
@internal
def _calc_interest_rate(amount: uint256, timespan: uint256, rate: uint128) -> uint256:
    return (amount * timespan * convert(rate, uint256)) / BPS_COEFFICIENT

@pure
@internal
def _calc_new_interest(deposit: uint256, principal: uint256, timespan: uint256, drate: uint128, frate: uint128) -> uint256:
    return self._calc_interest_rate(principal, timespan, drate) + self._calc_interest_rate(principal - deposit, timespan, frate)

@internal
def _accrue(p: Position, id: bytes32, amount: uint256) -> Position:
    if not p.isOpen:
        return p

    rate: Rate = self.rates[id]
    p.interestAccrued += self._calc_new_interest(
        p.deposit,
        p.principal,
        block.timestamp - rate.last_accrued,
        rate.drate,
        rate.frate
    )

    return p
    

@internal
def _repay(p: Position, id: bytes32, amount: uint256) -> Position:
    principal_repay: uint256 = amount
    if(p.interestAccrued != 0):
        if(amount > p.interestAccrued):
            p.interestAccrued = 0
            principal_repay = amount - p.interestAccrued
        else:
            p.interestAccrued -= amount
            principal_repay = 0

    if principal_repay != 0:
        p.principal -= principal_repay

    return p


@external
def depositAndRepay(id: bytes32, amount: uint256):
    self.credits[id] = self._repay(self.credits[id], id, amount)
    IERC20(self.credits[id].token).transferFrom(msg.sender, self, amount)

@external
def depositAndClose(id: bytes32, amount: uint256):
    owed: uint256 = self.credits[id].principal + self.credits[id].interestAccrued
    self.credits[id] = self._repay(self.credits[id], id, owed)
    IERC20(self.credits[id].token).transferFrom(msg.sender, self, owed)

@external
def close(id: bytes32):
    assert 0 == self.credits[id].principal
    self.credits[id] = self._repay(self.credits[id], id, self.credits[id].interestAccrued)
    IERC20(self.credits[id].token).transferFrom(msg.sender, self, self.credits[id].interestAccrued)

@external
def withdraw(id: bytes32,  amount: uint256): 
    IERC20(self.credits[id].token).transfer(self.credits[id].lender, amount)

# @external
# def claimAndRepay(claimToken: address, tradeData: Bytes[50000]) -> uint256: 

# @external
# def useAndRepay(amount: uint256) -> bool: 
#     IERC20(self.credits[id].token).transferFrom(msg.sender, self, amount)

# @external
# def declareInsolvent() -> bool: 

# @external
# def sweep(token: address, to: address) -> bool: 

# @external
# def liquidate(amount: uint256, targetToken: address)-> uint256: 

# @external
# def addSpigot(revenueContract: address, settings: Bytes[9])-> uint256: 