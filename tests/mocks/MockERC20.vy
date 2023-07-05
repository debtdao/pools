# @version 0.3.9
"""
@notice Mock ERC20 for testing
"""

from vyper.interfaces import ERC20 as IERC20

implements: IERC20

event Transfer:
	sender: indexed(address)
	receiver: indexed(address)
	amount: indexed(uint256)

event Approval:
	owner: indexed(address)
	spender: indexed(address)
	amount: indexed(uint256)

name: public(String[64])
symbol: public(String[32])
decimals: public(uint256)
balances: public(HashMap[address, uint256])
allowances: HashMap[address, HashMap[address, uint256]]
total_supply: uint256

nonces: public(HashMap[address, uint256])
DOMAIN_TYPE_HASH: constant(bytes32) = keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
PERMIT_TYPE_HASH: constant(bytes32) = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")

_CONTRACT_NAME: constant(String[18]) = "Mock ERC20"
_API_VERSION: constant(String[18]) = "0.0.1"

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


@external
def increaseAllowance(_spender: address, _amount: uint256) -> bool:
	newApproval: uint256 = self.allowances[msg.sender][_spender] + _amount
	self.allowances[msg.sender][_spender] = newApproval
	log Approval(msg.sender, _spender, newApproval)
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
def mint(_target: address, _value: uint256) -> bool:
    self.total_supply += _value
    return self._transfer(empty(address), _target, _value)


@internal
def _assert_caller_has_approval(_owner: address, _amount: uint256, _caller: address, _allowance: uint256):
	if msg.sender != _owner:
		allowance: uint256 = self.allowances[_owner][msg.sender]
		# MAX = unlimited approval (saves an SSTORE)
		if (allowance < max_value(uint256)):
			allowance = allowance - _amount
			self.allowances[_owner][msg.sender] = allowance
			# NOTE: Allows log filters to have a full accounting of allowance changes
			log Approval(_owner, msg.sender, allowance)

@internal
def _transfer(_sender: address, _receiver: address, _amount: uint256) -> bool:
	assert _receiver != self # dev: cant transfer to self

	if _sender != empty(address):
        self._assert_caller_has_approval(_sender, _amount, msg.sender, self.allowances[_sender][msg.sender])
        # if not minting, then ensure _sender has balance
        self.balances[_sender] -= _amount

	if _receiver != empty(address):
		# if not burning, add to _receiver
		# on burns shares dissapear but we still have logs to track existence
		self.balances[_receiver] += _amount

	log Transfer(_sender, _receiver, _amount)
	return True


event named_uint:
	num: indexed(uint256)
	str: indexed(String[100])

event named_addy:
	addy: indexed(address)
	str: indexed(String[100])


@view
@internal
def domain_separator() -> bytes32:
    return keccak256(
        concat(
            DOMAIN_TYPE_HASH,
            keccak256(_CONTRACT_NAME),
            keccak256(_API_VERSION),
            convert(chain.id, bytes32),
            convert(self, bytes32)
        )
    )

@view
@external
def DOMAIN_SEPARATOR() -> bytes32:
    return self.domain_separator()


@view
@external
def v() -> String[18]:
    return _API_VERSION

@view
@external
def n() -> String[18]:
    return _CONTRACT_NAME



@external
def permit(owner: address, spender: address, amount: uint256, expiry: uint256, signature: Bytes[65]) -> bool:
    """
    @notice
        Approves spender by owner's signature to expend owner's tokens.
        See https://eips.ethereum.org/EIPS/eip-2612.
    @param owner The address which is a source of funds and has signed the Permit.
    @param spender The address which is allowed to spend the funds.
    @param amount The amount of tokens to be spent.
    @param expiry The timestamp after which the Permit is no longer valid.
    @param signature A valid secp256k1 signature of Permit by owner encoded as r, s, v.
    @return True, if transaction completes successfully
    """
    assert owner != empty(address)  # dev: invalid owner
    assert expiry >= block.timestamp  # dev: permit expired
    nonce: uint256 = self.nonces[owner]
    digest: bytes32 = keccak256(
        concat(
            b'\x19\x01',
            self.domain_separator(),
            keccak256(
                concat(
                    PERMIT_TYPE_HASH,
                    convert(owner, bytes32),
                    convert(spender, bytes32),
                    convert(amount, bytes32),
                    convert(nonce, bytes32),
                    convert(expiry, bytes32),
                )
            )
        )
    )
    # NOTE: signature is packed as r, s, v
    r: uint256 = convert(slice(signature, 0, 32), uint256)
    s: uint256 = convert(slice(signature, 32, 32), uint256)
    v: uint256 = convert(slice(signature, 64, 1), uint256)
    assert ecrecover(digest, v, r, s) == owner  # dev: invalid signature
    self.allowances[owner][spender] = amount
    self.nonces[owner] = nonce + 1
    log Approval(owner, spender, amount)
    return True
