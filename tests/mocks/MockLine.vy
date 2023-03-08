# @version ^0.3.7
from vyper.interfaces import ERC20 as IERC20

interface ISecuredLine:
    def borrower() -> address: pure
    def ids(index: uint256) -> bytes32: view
    def status() -> uint8: view
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
INTEREST_RATE_COEFFICIENT: constant(uint256) = 315576000000 # (100% in bps * 364.25 days in seconds)

ids: public(uint256)
status: public(uint8)
borrower: public(address)
credits: public(HashMap[bytes32, Position])
rates: public(HashMap[bytes32, Rate])

STATUS_UNINITIALIZED: constant(uint8) = 0
STATUS_ACTIVE: constant(uint8) = 1
STATUS_LIQUIDATABLE: constant(uint8) = 2
STATUS_REPAID: constant(uint8) = 3
STATUS_INSOLVENT: constant(uint8) = 4


@external
def __init__(_borrower: address):
    self.status = 1
    self.borrower = _borrower
    self.status = STATUS_ACTIVE

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

@pure
@internal
def _calc_interest_rate(amount: uint256, timespan: uint256, rate: uint128) -> uint256:
    return (amount * timespan * convert(rate, uint256)) / INTEREST_RATE_COEFFICIENT

@pure
@internal
def _calc_new_interest(deposit: uint256, principal: uint256, timespan: uint256, drate: uint128, frate: uint128) -> uint256:
    return (self._calc_interest_rate(principal, timespan, drate) +
            self._calc_interest_rate(deposit - principal, timespan, frate))

@internal
def _accrue(p: Position, id: bytes32) -> Position:
    if not p.isOpen:
        return p

    rate: Rate = self.rates[id]
    
    log named_uint("timestamp", block.timestamp)
    log named_uint("last_accrued", rate.last_accrued)

    p.interestAccrued += self._calc_new_interest(
        p.deposit,
        p.principal,
        block.timestamp - rate.last_accrued,
        rate.drate,
        rate.frate
    )
    
    self.rates[id].last_accrued = block.timestamp

    return p
    
@internal
def _repay(p: Position, id: bytes32, amount: uint256) -> Position:
    assert amount <= p.principal + p.interestAccrued

    if(amount > p.interestAccrued):
        p.interestRepaid += p.interestAccrued
        p.principal -= amount - p.interestAccrued
        p.interestAccrued = 0
    else:
        p.interestRepaid += amount
        p.interestAccrued -= amount
    
    return p

@external
def accrueInterest(id: bytes32):
    self.credits[id] = self._accrue(self.credits[id], id)

@external
def setRates(id: bytes32, drate: uint128, frate: uint128): 
    self._set_rates(id, drate, frate)

@external
def increaseCredit(id: bytes32,  amount: uint256): 
    new_p: Position = self._accrue(self.credits[id], id)
    new_p.deposit += amount
    self.credits[id] = new_p
    IERC20(new_p.token).transferFrom(msg.sender, self, amount)

@external
def depositAndRepay(id: bytes32, amount: uint256):
    self.credits[id] = self._repay(self._accrue(self.credits[id], id), id, amount)
    IERC20(self.credits[id].token).transferFrom(msg.sender, self, amount)

@external
def depositAndClose(id: bytes32, amount: uint256):
    new_p: Position = self._accrue(self.credits[id], id)
    owed: uint256 = new_p.principal + new_p.interestAccrued
    self.credits[id] = self._repay(new_p, id, owed)
    IERC20(new_p.token).transferFrom(msg.sender, self, owed)

@external
def close(id: bytes32):
    assert 0 == self.credits[id].principal
    new_p: Position = self._accrue(self.credits[id], id)
    self.credits[id] = self._repay(new_p, id, new_p.interestAccrued)
    IERC20(new_p.token).transferFrom(msg.sender, self, new_p.interestAccrued)

@external
def withdraw(id: bytes32,  amount: uint256): 
    p: Position = self._accrue(self.credits[id], id)
    
    assert amount <= p.deposit + p.interestRepaid - p.principal 

    if amount > p.interestRepaid:
        p.deposit -= amount - p.interestRepaid
        p.interestRepaid = 0
    else:
        p.interestRepaid -= amount

    self.credits[id] = p
    IERC20(p.token).transfer(p.lender, amount)


@external
def borrow(id: bytes32,  amount: uint256): 
    p: Position = self._accrue(self.credits[id], id)
    
    assert amount <= p.deposit - p.principal 
    p.principal += amount

    self.credits[id] = p
    IERC20(p.token).transfer(self.borrower, amount)


@external
def declareInsolvent(): 
    self.status = STATUS_INSOLVENT

@external
def reset_position(id: bytes32): 
    self.credits[id] = Position({
        deposit: 0,
        principal: 0,
        interestAccrued: 0,
        interestRepaid: 0,
        decimals: 0,
        token: empty(address),
        lender: empty(address),
        isOpen: False,
    })


@external
def declareLiquidatable(): 
    self.status = STATUS_LIQUIDATABLE

@view
@external
def computeId(lender: address,  token: address) -> bytes32: 
    return keccak256(_abi_encode(self, lender, token))

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


event named_uint:
    note: String[200]
    value: uint256