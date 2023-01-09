# @version 0.3.7
# """
# @notice Simple ERC20 for tracking Chicken Bond tokens. Only controllable by chicken bond manager
# """

event Transfer:
    _from: indexed(address)
    _to: indexed(address)
    _value: uint256

event Approval:
    _owner: indexed(address)
    _spender: indexed(address)
    _value: uint256

name: immutable(String[64])
symbol: immutable(String[32])
decimals: immutable(uint256)
balanceOf: public(HashMap[address, uint256])
allowances: HashMap[address, HashMap[address, uint256]]
total_supply: uint256

manager: immutable(address)

@external
def __init__(_name: String[64], _symbol: String[32], _decimals: uint256, manager_: address):
    manager = manager_
    name = _name
    symbol = _symbol
    decimals = _decimals


@external
@view
def totalSupply() -> uint256:
    return self.total_supply


@external
@view
def allowance(_owner : address, _spender : address) -> uint256:
    return self.allowances[_owner][_spender]


@internal
def _transfer(_from: address, _to : address, _value : uint256) -> bool:
    self.balanceOf[_from] -= _value
    self.balanceOf[_to] += _value
    log Transfer(_from, _to, _value)
    return True

@external
def transfer(_to : address, _value : uint256) -> bool:
    return self._transfer(msg.sender, _to, _value)


@external
def transferFrom(_from : address, _to : address, _value : uint256) -> bool:
    allowance: uint256 = self.allowances[_from][_to]
    # MAX = unlimited approval (saves an SSTORE)
    if (allowance < max_value(uint256)):
        allowance = allowance - _value
        self.allowances[_from][_to] = allowance
        # NOTE: Allows log filters to have a full accounting of allowance changes
        log Approval(_from, _to, allowance)

    return self._transfer(_from, _to, _value)

@external
def approve(_spender : address, _value : uint256) -> bool:
    self.allowances[msg.sender][_spender] = _value
    log Approval(msg.sender, _spender, _value)
    return True


@external
def mint(_target: address, _value: uint256) -> bool:
    assert msg.sender == manager
    return self._transfer(empty(address), _target, _value)

@external
def burn(_target: address, _value: uint256) -> bool:
    assert msg.sender == manager
    return self._transfer(_target, empty(address), _value)