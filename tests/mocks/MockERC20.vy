# @version 0.3.7
"""
@notice Mock ERC20 for testing
"""

event Transfer:
    _from: indexed(address)
    _to: indexed(address)
    _value: uint256

event Approval:
    _owner: indexed(address)
    _spender: indexed(address)
    _value: uint256

name: public(String[64])
symbol: public(String[32])
decimals: public(uint256)
balances: public(HashMap[address, uint256])
allowances: HashMap[address, HashMap[address, uint256]]
total_supply: uint256


@external
def __init__(_name: String[64], _symbol: String[32], _decimals: uint256):
    self.name = _name
    self.symbol = _symbol
    self.decimals = _decimals
    # raise "question reality"


@external
@view
def totalSupply() -> uint256:
    return self.total_supply

@external
@view
def balanceOf(_owner: address) -> uint256:
    return self.balances[_owner]


@external
@view
def allowance(_owner : address, _spender : address) -> uint256:
    return self.allowances[_owner][_spender]



@internal
def _assert_caller_has_approval(_owner: address, _amount: uint256) -> bool:
	if msg.sender != _owner:
		allowance: uint256 = self.allowances[_owner][msg.sender]

		log named_uint(allowance, "allowance")
		log named_uint(_amount, "amount")
		log named_addy(msg.sender, "caller")
		log named_addy(_owner, "_owner")

		# MAX = unlimited approval (saves an SSTORE)
		if (allowance < max_value(uint256)):
			allowance = allowance - _amount
			self.allowances[_owner][msg.sender] = allowance
			# NOTE: Allows log filters to have a full accounting of allowance changes
			log Approval(_owner, msg.sender, allowance)

	return True

@internal
def _transfer(_sender: address, _receiver: address, _amount: uint256) -> bool:
	assert _receiver != self # dev: cant transfer to self

	if _sender != empty(address):
        self._assert_caller_has_approval(_sender, _amount)
        # if not minting, then ensure _sender has balance
        self.balances[_sender] -= _amount

	if _receiver != empty(address):
		# if not burning, add to _receiver
		# on burns shares dissapear but we still have logs to track existence
		self.balances[_receiver] += _amount

	log Transfer(_sender, _receiver, _amount)
	return True


@external
def transfer(_to : address, _value : uint256) -> bool:
    return self._transfer(msg.sender, _to, _value)


@external
def transferFrom(_from : address, _to : address, _value : uint256) -> bool:
    return self._transfer(_from, _to, _value)


@external
def approve(_spender : address, _value : uint256) -> bool:
    self.allowances[msg.sender][_spender] = _value
    log Approval(msg.sender, _spender, _value)
    return True


@external
def _mint_for_testing(_target: address, _value: uint256) -> bool:
	return self._transfer(empty(address), _target, _value)

event named_uint:
	num: indexed(uint256)
	str: indexed(String[100])

event named_addy:
	addy: indexed(address)
	str: indexed(String[100])
