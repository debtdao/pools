# @version ^0.3.7

"""
@title 	Debt DAO Lending Pool
@author	Kiba Gateaux
@notice	Tokenized, liquid 4626 pool allowing depositors to collectively lend to Debt DAO Line of Credit contracts
@dev	All investment decisions and pool paramters are controlled by the pool owner aka "Delegate"



TODO - 
1. Refactor yearn permit()  so args are exactly 2612 standard
2. Add permit + permit2 IERC4626P extension and implement functions
2. add IERC4626RP (referral + permit)
3. Make sure using appropriate instances of total_assets, total_deployed, liquid_assets, owned_assets, etc. in state updates and price algorithms
4. add dev: revert strings to all asserts
5. understand how DEGREDATION_COEFFICIENT works
6. implement _get_share_APR()
"""

# interfaces defined at bottom of file
implements: IERC20
implements: IERC2612
implements: IERC3156
implements: IERC4626
implements: IERC4626R
implements: IPoolDelegate

# this contracts interface for reference
interface IPoolDelegate:
	# getters
	def APR() -> int256: view
	def price() -> uint256: view

	# investments
	def unlock_profits() -> uint256: nonpayable
	def collect_interest(line: address, id: bytes32) -> uint256: nonpayable
	def increase_credit( line: address, id: bytes32, amount: uint256) -> bool: nonpayable
	def set_rates( line: address, id: bytes32, drate: uint128, frate: uint128) -> bool: nonpayable
	def add_credit( line: address, drate: uint128, frate: uint128, amount: uint256) -> bytes32: nonpayable

	# divestment and loss
	def impair(line: address, id: bytes32) -> (uint256, uint256): nonpayable
	def reduce_credit(line: address, id: bytes32, amount: uint256) -> (uint256, uint256): nonpayable
	def use_and_repay(line: address, repay: uint256, withdraw: uint256) -> (uint256, uint256): nonpayable
	
	# external 4626 interactions
	def divest_4626(vault: address, amount: uint256) -> bool: nonpayable
	def invest_4626(vault: address, amount: uint256) -> uint256: nonpayable

	# Pool Admin
	def accept_owner() -> bool: nonpayable
	def update_owner(new_owner_: address) -> bool: nonpayable
	def update_max_assets(new_max: uint256) -> bool: nonpayable
	def update_min_deposit(new_min: uint256) -> bool: nonpayable
	def update_profit_degredation(degradation: uint256): nonpayable

	# fees
	def update_fee_recipient(newRecipient: address) -> bool: nonpayable
	def accept_fee_recipient(newRecipient: address) -> bool: nonpayable
	def update_performance_fee(fee: uint16) -> bool: nonpayable
	def update_collector_fee(fee: uint16) -> bool: nonpayable
	def update_withdraw_fee(fee: uint16) -> bool: nonpayable
	def update_deposit_fee(fee: uint16) -> bool: nonpayable
	def update_flash_fee(fee: uint16) -> bool: nonpayable
	def claim_fees(amount: uint256) -> bool: nonpayable


### Constants

# @notice LineLib.STATUS.INSOLVENT
INSOLVENT_STATUS: constant(uint256) = 4
# @notice 8 decimals. padding when calculating for better accuracy
PRICE_DECIMALS: constant(uint256) = 10**8
# @notice 100% in bps. Used to divide after multiplying bps fees. Also max performance fee.
FEE_COEFFICIENT: constant(uint16) = 10000
# @notice 30% in bps. snitch gets 1/3  of owners fees when liquidated to repay impairment.
# IF owner fees exist when snitched on. Pool depositors are *guaranteed* to see a price increase, hence heavy incentive to snitches.
SNITCH_FEE: constant(uint16) = 3000
# @notice 5% in bps. Max fee that can be charged for non-performance fee
MAX_PITTANCE_FEE: constant(uint16) = 200
# @notice EIP712 contract name
CONTRACT_NAME: constant(String[13]) = "Debt DAO Pool"
# @notice EIP712 contract version
API_VERSION: constant(String[7]) = "0.0.001"
# @notice EIP712 type hash
DOMAIN_TYPE_HASH: constant(bytes32) = keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
# @notice EIP712 permit type hash
PERMIT_TYPE_HASH: constant(bytes32) = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
# TODO rename DEGRADATION_COEFFICIENT
# rate per block of profit degradation. DEGRADATION_COEFFICIENT is 100% per block
DEGRADATION_COEFFICIENT: constant(uint256) = 10 ** 18

# IERC20 vars
NAME: public(immutable(String[50]))
SYMBOL: public(immutable(String[18]))
DECIMALS: public(immutable(uint8))
# total amount of shares in pool
total_supply: public(uint256)
# balance of pool vault shares
balances: HashMap[address, uint256]
# owner -> spender -> amount approved
allowances: HashMap[address, HashMap[address, uint256]]

# IERC4626 vars
# underlying token for pool/vault
asset: public(immutable(address))
# total notional amount of underlying token owned by pool (may not be currently held in pool)
total_assets: public(uint256)

# share price logic stolen from yearn vyper vaults
# vars - https://github.com/yearn/yearn-vaults/blob/74364b2c33bd0ee009ece975c157f065b592eeaf/contracts/Vault.vy#L239-L242
last_report: public(uint256) 	# block.timestamp of last report
locked_profit: public(uint256) 	# how much profit is locked and cant be withdrawn
# lower the coefficient the slower the profit drip
locked_profit_degradation: public(uint256) # The rate of degradation in percent per second scaled to 1e18.  DEGRADATION_COEFFICIENT is 100% per block

# IERC2612 Variables
nonces: public(HashMap[address, uint256])
# cheap retrieval of domain separator if no chainforks
CACHED_CHAIN_ID: public(immutable(uint256))
CACHED_COMAIN_SEPARATOR: public(immutable(bytes32))


# Pool Delegate Variables

# asset manager who directs funds into investment strategies
owner: public(address)
# address to migrate delegate powers to. Must be accepted before transfer occurs
pending_owner: public(address)
# address that can claim pool delegates fees
fee_recipient: public(address)
# address to migrate revenuestream to. Must be accepted before transfer occurs
pending_fee_recipient: public(address)
# shares earned by Delegate for managing pool
accrued_fees: public(uint256)
# minimum amount of assets that can be deposited at once. whales only, fuck plebs.
min_deposit: public(uint256)
# maximum amount of asset deposits to allow into pool
max_assets: public(uint256)
# total amount of asset held externally in lines or vaults
total_deployed: public(uint256)
# amount of assets held by external 4626 vaults. used to calc profit/loss on non-line investments
vault_investments: public(HashMap[address, uint256])


struct Fees:
	# Fee types #0-2 go to pool owner

	# % (in bps) of profit that delegate keeps to align incentives
	performance: uint16
	# % fee (in bps) to charge pool depositors and give to delegate
	deposit: uint16
	# % fee (in bps) on share redemption for underlying assets
	withdraw: uint16

	# Fee type #3 go to pool shares directly

	# % fee (in bps) to charge flash borrowers
	flash: uint16
	
	# Fee types #4-5 go to ecosystem service providers

	# % (in bps) of performance fee to give to caller for automated collections
	collector: uint16
	# % fee (in bps) to charge pool depositors and give to referrers
	referral: uint16

enum FEE_TYPES:
	# should be same order as Fees struct
	PERFORMANCE
	DEPOSIT
	WITHDRAW
	FLASH
	COLLECTOR
	REFERRAL
	SNITCH

fees: public(Fees)


@external
def __init__(
  	_delegate: address,
	_asset: address,
	_name: String[34],
	_symbol: String[9],
	_fees: Fees,
):
	"""
	@notice				A generalized pooling contact to aggregate deposits and lend to trustless lines of credit
	@param _delegate	who will own and control the pool
	@param _asset 		ERC20 token to deposit and lend. Must verify asset is supported by oracle on Lines you want to invest in.
	@param _name 		custom pool name. first 0-13 chars are templated  "Debt DAO Pool - {_name}"
	@param _symbol 		custom pool symbol. first 9 chars are templated  "ddp{_asset.symbol}-{_symbol}"
	@param _fees 		fees to charge on pool
	"""
	
	# CONFUSING
	self.owner = msg.sender # set owner to deployer for validation functions
	self._assert_max_fee(_fees.performance, FEE_TYPES.PERFORMANCE) # max 100% performance fee
	self._assert_pittance_fee(_fees.collector, FEE_TYPES.COLLECTOR)
	self._assert_pittance_fee(_fees.flash, FEE_TYPES.FLASH)
	self._assert_pittance_fee(_fees.referral, FEE_TYPES.REFERRAL)
	self._assert_pittance_fee(_fees.deposit, FEE_TYPES.DEPOSIT)
	self._assert_pittance_fee(_fees.withdraw, FEE_TYPES.WITHDRAW)

	# Setup Pool variables
	assert _delegate != empty(address)
	self.owner = _delegate
	self.fees = _fees

	# IERC20 vars
	NAME = self._get_pool_name(_name)
	SYMBOL = self._get_pool_symbol(_asset, _symbol)

	# MUST use same decimals as `asset` token. revert if call fails
	# We do not account for differening token decimals in our math
	DECIMALS = IERC20Detailed(_asset).decimals()
	assert DECIMALS != 0

	# IERC4626
	asset = _asset

	# NOTE: Yearn - set profit to be distributed every 6 hours
	# self.locked_profit_degradation = convert(DEGRADATION_COEFFICIENT * 46 / 10 ** 6 , uint256)

	# TODO: Debt DAO - set profit to bedistributed to every `1 eek` (ethereum week)
	# 2048 epochs = 2048 blocks = COEFFICIENT / 2048 / 10 ** 6 ???
	self.locked_profit_degradation = convert(DEGRADATION_COEFFICIENT * 46 / 10 ** 6 , uint256)

	#ERC2612
	CACHED_CHAIN_ID = chain.id # cache before compute
	CACHED_COMAIN_SEPARATOR = self.domain_separator()


### Investing functions

@internal
def _assert_delegate_has_available_funds(amount: uint256):
	assert msg.sender == self.owner
	assert self.total_assets - self.total_deployed >= amount

@external
@nonreentrant("lock")
def add_credit(line: address, drate: uint128, frate: uint128, amount: uint256) -> bytes32:
	self._assert_delegate_has_available_funds(amount)
	
	self.total_deployed += amount
	
	# NOTE: no need to log, Line emits events already
	return ISecuredLine(line).addCredit(drate, frate, amount, asset, self)

@external
@nonreentrant("lock")
def increase_credit(line: address, id: bytes32, amount: uint256) -> bool:
	self._assert_delegate_has_available_funds(amount)

	self.total_deployed += amount

	# NOTE: no need to log, Line emits events already
	return ISecuredLine(line).increaseCredit(id, amount)

@external
def set_rates(line: address, id: bytes32, drate: uint128, frate: uint128) -> bool:
	assert msg.sender == self.owner
	# NOTE: no need to log, Line emits events already
	return ISecuredLine(line).setRates(id, drate, frate)

@external
@nonreentrant("lock")
def collect_interest(line: address, id: bytes32) -> uint256:
	"""
	@notice
		Anyone can claim interest from active lines and start vesting profits into pool shares
	@return
		Amount of assets earned in usury
	"""
	return self._reduce_credit(line, id, 0)[1]

@external
@nonreentrant("lock")
def abort(line: address, id: bytes32) -> (uint256, uint256):
	"""
	@notice emergency cord to remove all avialable funds from a line (deposit + interestRepaid)
	"""
	assert msg.sender == self.owner
	return self._reduce_credit(line, id, max_value(uint256))

@external
@nonreentrant("lock")
def reduce_credit(line: address, id: bytes32, amount: uint256) -> (uint256, uint256):
	assert msg.sender == self.owner
	return self._reduce_credit(line, id, amount)

@external
@nonreentrant("lock")
def use_and_repay(line: address, repay: uint256, withdraw: uint256) -> (uint256, uint256):
	assert msg.sender == self.owner

	# Assume we are next lender in queue. 
	# save id for later incase we repay full amount and stepQ
	id: bytes32 = ISecuredLine(line).ids(0)

	# NOTE: no need to log, Line emits events already
	assert ISecuredLine(line).useAndRepay(repay)

	return self._reduce_credit(line, id, withdraw)

# THIS IS THE BIG ONE - IMPAIRMENT

@external
@nonreentrant("lock")
def impair(line: address, id: bytes32) -> (uint256, uint256):
	"""
	@notice     - markdown the value of an insolvent loan reducing vault share price over time
				- Callable by anyone to prevent delegate from preventing numba go down
	@param line - line of credit contract to call
	@param id   - credit position on line controlled by this pool 
	"""
	assert ISecuredLine(line).status() == INSOLVENT_STATUS

	position: Position = ISecuredLine(line).credits(id)

	recoverable: uint256 = position.deposit - position.principal

	ISecuredLine(line).withdraw(id, recoverable + position.interestRepaid) # claim all funds left in line

	# snapshot APR before updating share prices
	old_apr: int256 = self._get_share_APR()
	share_price: uint256 = self._get_share_price()

	asset_diff: uint256 = 0
	fees_burned: uint256 = 0
	if position.principal != 0:
		(asset_diff, fees_burned) = self._update_shares(position.principal, True)
		# snitch was successful
		if fees_burned != 0 and msg.sender != self.owner:
			self._calc_and_mint_fee(self, msg.sender, fees_burned, SNITCH_FEE, FEE_TYPES.SNITCH)


	# we deduct lost principal but add gained interest
	if position.interestRepaid != 0:
		self._update_shares(position.interestRepaid)
		# NOTE: no need to log, Line emits events already
		# NOTE: Delegate abdicates right to performance fee on impairment

	log Impair(id, recoverable, position.principal, old_apr, self._get_share_APR(), share_price, fees_burned)

	return (recoverable, position.principal)

### External 4626 vault investing

@external
@nonreentrant("lock")
def invest_4626(_vault: address, _amount: uint256) -> uint256:
	self._assert_delegate_has_available_funds(_amount)

	self.total_deployed += _amount
	self.vault_investments[_vault] += _amount

	# NOTE: Delegate should check previewDeposit(`_amount`) expected vs `_amount` for slippage ?
	shares: uint256 = IERC4626(_vault).deposit(_amount, self)

	log Invest4626(_vault, _amount, shares) ## TODO shares
	return shares


@external
@nonreentrant("lock")
def divest_4626(_vault: address, _amount: uint256) -> bool:

	net: int256 = 0

	curr_shares: uint256 = IERC20(_vault).balanceOf(self) 
	# could do is_loss here with previewWithdraw

	# add max_value(uint256) _amount shorthand to pull all vault funds using balanceOf

	initial_deposit: uint256 = self.vault_investments[_vault]


	if initial_deposit == 0 and curr_shares == 0: # nothing to account for
		return True

	if initial_deposit == 0:
		# we already recouped principal. this is all profit
		net = convert(_amount, int256)
		self._update_shares(_amount)
	else:
		# TODO this branch shouldnt be done if is_loss

		# no profit or loss. Just retrieving principal
		# net = 0 # no change in net, default is 0


		self.total_deployed -= _amount
		self.vault_investments[_vault] -= _amount


	# TODO TEST check that investing, then partially divesting at a loss, then investing more, then divesting more at a profit and/or loss updates our pool share price appropriately

	# NOTE: Delegate should check previewDeposit(`_amount`) expected vs `_amount` for slippage ?
	burned_shares: uint256 = IERC4626(_vault).withdraw(_amount, self, self)

	# curr_shares == burned_shares should still work if _amount == 0
	# TODO would be nice if this logic could be earlier so could do caller assertion for snitching
	is_loss: bool = curr_shares == burned_shares and self.vault_investments[_vault] != 0
	if is_loss:
		# redeemed all shares but didnt recoup all assets

		# TODO still need to withdraw here, just amount withdraw will be
		net = -convert(initial_deposit, int256)
		self._update_shares(initial_deposit, True)
	else:
		# only delegate can divest if profitable
		# allow anyone to call if snitching a loss and claim delegate fees
		assert msg.sender == self.owner

	log Divest4626(_vault, _amount, 0, net)

	# delegate doesnt earn fees on 4626 strategies to incentivize line investment
	return True


@external
def sweep(token: address, amount: uint256 = max_value(uint256)):
    """
    @notice
        Removes tokens from this Vault that are not the type of token managed
        by this Vault. This may be used in case of accidentally sending the
        wrong kind of token to this Vault.
        Tokens will be sent to `governance`.
        This will fail if an attempt is made to sweep the tokens that this
        Vault manages.
        This may only be called by governance.
    @param token The token to transfer out of this vault.
    @param amount The quantity or tokenId to transfer out.
    """
    assert msg.sender == self.owner
    
    value: uint256 = amount
    if token == asset:
		# recover assets sent directly to pool
		# Can't be used to steal what this Vault is protecting
        value = IERC20(asset).balanceOf(self) - (self.total_assets - self.total_deployed)
    elif value == max_value(uint256):
        value = IERC20(token).balanceOf(self)


    log Sweep(token, value)
    self._erc20_safe_transfer(token, self.owner, value)


### Pool Admin

@external
def update_owner(new_owner: address) -> bool:
	assert msg.sender == self.owner
	self.pending_owner = new_owner
	log NewPendingOwner(new_owner)
	return True

@external
def accept_owner() -> bool:
	assert msg.sender == self.pending_owner
	self.owner = self.pending_owner
	log UpdateOwner(self.pending_owner)
	return True

# THS IS COOL^

@external
def update_min_deposit(new_min: uint256)  -> bool:
	assert msg.sender == self.owner
	self.min_deposit = new_min
	log UpdateMinDeposit(new_min)
	return True

@external
def update_max_assets(new_max: uint256)  -> bool:
	assert msg.sender == self.owner
	self.max_assets = new_max
	log UpdateMaxAssets(new_max)
	return True


### Manage Pool Fees

@internal
def _assert_max_fee(fee: uint16, fee_type: FEE_TYPES) -> bool:
  assert msg.sender == self.owner
  assert fee <= FEE_COEFFICIENT # max 100% performance fee
  log UpdateFee(fee, fee_type)
  return True

@external
@nonreentrant("lock")
def update_performance_fee(fee: uint16) -> bool:
  self.fees.performance = fee
  return self._assert_max_fee(fee, FEE_TYPES.PERFORMANCE)

@internal
def _assert_pittance_fee(fee: uint16, fee_type: FEE_TYPES) -> bool:
	assert msg.sender == self.owner
	assert fee <= MAX_PITTANCE_FEE
	log UpdateFee(fee, fee_type)
	return True

@external
@nonreentrant("lock")
def update_flash_fee(fee: uint16) -> bool:
	self.fees.flash = fee
	return self._assert_pittance_fee(fee, FEE_TYPES.FLASH)

@external
@nonreentrant("lock")
def update_collector_fee(fee: uint16) -> bool:
	self.fees.collector = fee
	return self._assert_pittance_fee(fee, FEE_TYPES.COLLECTOR)

@external
@nonreentrant("lock")
def update_deposit_fee(fee: uint16) -> bool:
	self.fees.collector = fee
	return self._assert_pittance_fee(fee, FEE_TYPES.DEPOSIT)

@external
@nonreentrant("lock")
def update_withdraw_fee(fee: uint16) -> bool:
	self.fees.collector = fee
	return self._assert_pittance_fee(fee, FEE_TYPES.WITHDRAW)

@external
def update_fee_recipient(new_recipient: address) -> bool:
  assert msg.sender == self.fee_recipient
  self.pending_fee_recipient = new_recipient
  log NewPendingFeeRecipient(new_recipient)
  return True

@external
def accept_fee_recipient(newRecipient: address) -> bool:
  assert msg.sender == self.pending_fee_recipient
  self.fee_recipient = msg.sender
  log AcceptFeeRecipient(msg.sender)
  return True

@external
@nonreentrant("lock")
def claim_fees(amount: uint256) -> bool:
	assert msg.sender == self.fee_recipient
	
	apr: int256 = self._get_share_APR()
	assert apr > 0 # TODO bitshift, cast uint, and check != 0 for cheaper gas ???

	# set amount to claim
	claimed: uint256 = amount
	if amount == max_value(uint256):
		claimed = self.accrued_fees # set to max available
	
	# transfer fee shares locked in pool to fee recipient
	self.accrued_fees -= claimed
	self._transfer(self, msg.sender, claimed)

	log OwnerFeeClaimed(self.fee_recipient, claimed)
	price: uint256 = self._get_share_price()
	log TrackSharePrice(price, price, apr)

	return True

@external
@nonreentrant("lock")
def update_profit_degredation(degradation: uint256):
    """
    @notice
        Changes the locked profit degradation.
    @param degradation The rate of degradation in percent per second scaled to 1e18.
    """
    assert msg.sender == self.owner
    # Since "degradation" is of type uint256 it can never be less than zero
    assert degradation <= DEGRADATION_COEFFICIENT
    self.locked_profit_degradation = degradation
    log UpdateProfitDegredation(degradation) 


### ERC4626 Functions

@external
@nonreentrant("lock")
def unlock_profits() -> uint256:
	return self._unlock_profits()

@external
@nonreentrant("lock")
def deposit(_assets: uint256, _receiver: address) -> uint256:
	"""
		@return - shares
	"""
	return self._deposit(_assets, _receiver)

@external
@nonreentrant("lock")
def depositWithReferral(_assets: uint256, _receiver: address, _referrer: address) -> uint256:
	"""
		@return - shares
	"""
	return self._deposit(_assets, _receiver, _referrer)


@external
@nonreentrant("lock")
def depositWithPermit(_assets: uint256, _receiver: address, deadline: uint256, signature: Bytes[65]) -> uint256:
	"""
		@return - shares
	"""
	IERC2612(asset).permit(msg.sender, self, _assets, deadline, signature)
	return self._deposit(_assets, _receiver)


@external
@nonreentrant("lock")
def mint(_shares: uint256, _receiver: address) -> uint256:
	"""
		@return - assets
	"""
	share_price: uint256 = self._get_share_price()
	# TODO TEST https://github.com/fubuloubu/ERC4626/blob/55e22a6757b79abf733bfcaef8d1096311a5314f/contracts/VyperVault.vy#L181-L182
	return self._deposit(_shares * share_price, _receiver) * share_price

@external
@nonreentrant("lock")
def mintWithReferral(_shares: uint256, _receiver: address, _referrer: address) -> uint256:
	"""
		@return - assets
	"""
	share_price: uint256 = self._get_share_price()
	return self._deposit(_shares * share_price, _receiver, _referrer) * share_price

@external
@nonreentrant("lock")
def withdraw(
	assets: uint256,
	receiver: address,
	owner: address
) -> uint256:
	"""
		@return - shares
	"""
	return self._withdraw(assets, owner, receiver)

@external
@nonreentrant("lock")
def redeem(shares: uint256, receiver: address, owner: address) -> uint256:
	"""
		@return - assets
	"""
	share_price: uint256 = self._get_share_price()
	return self._withdraw(shares * share_price, owner, receiver) * share_price

### ERC20 Functions

@external
@nonreentrant("lock")
def transfer(to: address, amount: uint256) -> bool:
  return self._transfer(msg.sender, to, amount)

@external
@nonreentrant("lock")
def transferFrom(sender: address, receiver: address, amount: uint256) -> bool:
	assert self._caller_has_approval(sender, amount)
	return self._transfer(sender, receiver, amount)


@external
def approve(spender: address, amount: uint256) -> bool:
	self.allowances[msg.sender][spender] = amount
	log Approval(msg.sender, spender, amount)
	return True

@external
def increaseAllowance(spender: address, amount: uint256) -> bool:
	newApproval: uint256 = self.allowances[msg.sender][spender] + amount
	self.allowances[msg.sender][spender] = newApproval
	log Approval(msg.sender, spender, newApproval)
	return True


### Internal Functions 

# transfer + approve vault shares
@internal
def _transfer(sender: address, receiver: address, amount: uint256) -> bool:
	# prevent locking funds and yUSD/CREAM style share price attacks
	assert receiver != self # dev: cant transfer to self

	if sender != empty(address):
		# if not minting, then ensure sender has balance
		self.balances[sender] -= amount
	
	if receiver != empty(address):
		# if not burning, add to receiver
		# on burns shares dissapear but we still have logs to track existence
		self.balances[receiver] += amount
	

	log Transfer(sender, receiver, amount)
	return True

@internal
def _caller_has_approval(_owner: address, _amount: uint256) -> bool:
	if msg.sender != _owner:
		allowance: uint256 = self.allowances[_owner][msg.sender]
		# MAX = unlimited approval (saves an SSTORE)
		if (allowance < max_value(uint256)):
			allowance = allowance - _amount
			self.allowances[_owner][msg.sender] = allowance
			# NOTE: Allows log filters to have a full accounting of allowance changes
			log Approval(_owner, msg.sender, allowance)

	return True

@internal
def _erc20_safe_transfer(_token: address, receiver: address, amount: uint256):
    # Used only to send tokens that are not the type managed by this Vault.
    # HACK: Used to handle non-compliant tokens like USDT
    response: Bytes[32] = raw_call(
        _token,
        concat(
            method_id("transfer(address,uint256)"),
            convert(receiver, bytes32),
            convert(amount, bytes32),
        ),
        max_outsize=32,
		revert_on_failure=True
    )
    if len(response) > 0:
        assert convert(response, bool), "Transfer failed!"


# 4626 + Pool internal functions

# inflate supply to take fees. reduce share price. tax efficient.


@internal
def _mint(to: address, shares: uint256, assets: uint256) -> bool:
	"""
	@notice
		Inc internal supply with new assets deposited and shares minted
	"""
	self.total_assets += assets
	self.total_supply += shares
	self._transfer(empty(address), to, shares)
	return True

@internal
def _burn(owner: address, shares: uint256, assets: uint256) -> bool:
	"""
	"""
	self.total_assets -= assets
	self.total_supply -= shares
	self._transfer(owner, empty(address), shares)
	return True

@internal
def _calc_and_mint_fee(
	payer: address,
	to: address,
	shares: uint256,
	fee: uint16,
	feeType: FEE_TYPES
) -> uint256:
	"""
		@notice - inflate supply, reduce share price, and distribute new shares to ecosystem service provider.
				- more tax efficient to manipulate share price vs directly charge users a fee
	"""
	fees: uint256 = self._calc_fee(shares, fee)
	if(fees != 0):
		if(to == self.owner):
			# store delegate fees separetly from delegate balance so we can slash if neccessary
			assert self._mint(self, fees, fees * self._get_share_price())
			self.accrued_fees += fees
		else:
			# mint other ecosystem participants fees to them directly
			assert self._mint(to, fees, fees * self._get_share_price())

	# log fees even if 0 so we can simulate potential fee structures post-deployment
	log FeesGenerated(payer, to, fees, shares, feeType)
		
	return fees


@internal
@pure
def _calc_fee(shares: uint256, fee: uint16) -> uint256:
	"""
	@dev	does NOT emit `log FeesGenerated` like _mint_and_calc. Must manuualy log if using this function whil changing state
	"""
	if fee == 0:
		return 0
	else:
		return (shares * convert(fee, uint256)) / convert(FEE_COEFFICIENT, uint256)

@internal 
def _reduce_credit(line: address, id: bytes32, amount: uint256) -> (uint256, uint256):
	"""
	@notice		withdraw deposit and/or interest from an external position
	@return 	(initial principal withdrawn, usurious interest earned)
	"""
	withdrawable: uint256 = amount
	interest: uint256 = 0
	deposit: uint256 = 0
	(deposit, interest) = ISecuredLine(line).available(id)

	if amount == 0:
		# 0 is shorthand for take maximum amount of interest
		withdrawable = interest
	elif amount == max_value(uint256):
		# MAX is shorthand for all assets
		withdrawable = deposit + interest

	# set how much deposit vs interest we are collecting
	# NOTE: MUST come after `amount` shorthand checks
	if withdrawable < interest:
		# if we want less than claimable interest, reduce incoming interest
		interest = withdrawable
		deposit = 0
	else:
		# we are withdrawing initial deposit in addition to interest
		deposit = withdrawable - interest
		# TODO TEST this random side effect here
		self.total_deployed -= deposit # return principal to liquid pool

	if interest != 0:
		# update share price with new profits
		self._update_shares(interest, False)

		# payout fees with new share price
		# TODO TEST does taking fees before/after updating shares affect RDT ???
		fees: uint256 = self._take_performance_fee(interest)

	# NOTE: no need to log, Line emits events already
	assert ISecuredLine(line).withdraw(id, withdrawable)

	return (deposit, interest)

@internal
def _take_performance_fee(interest_earned: uint256) -> uint256:
	"""
	@notice takes total profits earned and takes fees for delegate and compounder
	@dev fees are stored as shares but input/ouput assets
	@param interest_earned - total amount of assets claimed from usurious activities
	@return total amount of shares taken as fees
	"""
	share_price: uint256 = self._get_share_price()
	shares_earned: uint256 = interest_earned / share_price

	performance_fee: uint256 = self._calc_and_mint_fee(self, self.owner, shares_earned, self.fees.performance, FEE_TYPES.PERFORMANCE)

	collector_fee: uint256 = self._calc_fee(shares_earned, self.fees.collector)
	if (collector_fee != 0 and msg.sender != self.owner):
		# NOTE: only _calc not _mint_and_calc so caller gets collector fees in raw asset for easier MEV
		# NOTE: use pre performance fee inflation price for payout
		collect_assets: uint256 = collector_fee * share_price
		self.total_assets -= collect_assets
		self._erc20_safe_transfer(asset, msg.sender, collect_assets)
		log FeesGenerated(self, msg.sender, collector_fee, shares_earned, FEE_TYPES.COLLECTOR)

	return performance_fee + collector_fee


@internal
def _deposit(
	assets: uint256,
	receiver: address,
	referrer: address = empty(address)
) -> uint256:
	"""
	adds shares to a user after depositing into vault
	priviliged internal func
	"""
	assert assets >= self.min_deposit # dev: FUCK PLEBS
	assert self.total_assets + assets <= self.max_assets # dev: Pool max reached
	
	share_price: uint256 = self._get_share_price()
	shares: uint256 = assets / share_price

	if self.fees.deposit != 0:
		self._calc_and_mint_fee(receiver, self.owner, shares, self.fees.deposit, FEE_TYPES.DEPOSIT)

	if referrer != empty(address) and self.fees.referral != 0:
		self._calc_and_mint_fee(receiver, referrer, shares, self.fees.referral, FEE_TYPES.REFERRAL)

	# TODO test how  deposit/refer fee inflatino affects the shares/asssets that they are *supposed* to lose

	# use original price, opposite of _withdraw, requires them to deposit more assets than current price post fee inflation
	self._mint(receiver, shares, assets)

	assert IERC20(asset).transferFrom(msg.sender, self, assets) # dev: asset.transferFrom() failed on deposit

	log Deposit(shares, receiver, msg.sender, assets)
	# log price change after deposit and fee inflation
	log TrackSharePrice(share_price, self._get_share_price(), self._get_share_APR())

	return shares

@internal
def _withdraw(
	assets: uint256,
	owner: address,
	receiver: address
) -> uint256:
	assert assets <= self._get_max_liquid_assets() 	# dev: insufficient liquidity
	assert self._caller_has_approval(owner, assets) # dev: insufficient allowance

	share_price: uint256 = self._get_share_price()
	shares: uint256 = assets / share_price
	# TODO TEST  https://github.com/fubuloubu/ERC4626/blob/55e22a6757b79abf733bfcaef8d1096311a5314f/contracts/VyperVault.vy#L214-L216

	# TODO test how  withdraw fee inflatino affects the shares/asssets that they are *supposed* to lose
		
	# use _calc not _mint_and_calc. minting does not affect withdrawer who should be penalized, only other pool depositors.
	# make them burn extra shares instead of inflating
	withdraw_fee: uint256 = self._calc_fee(shares, self.fees.withdraw)
	if self.fees.withdraw != 0: # only log if fee needed
		log FeesGenerated(receiver, self.owner, withdraw_fee, shares,  FEE_TYPES.WITHDRAW)

	#  remove assets/shares from pool
	self._burn(receiver, shares + withdraw_fee, assets)
	
	#  transfer assets to withdrawer
	self._erc20_safe_transfer(asset, receiver, assets)

	log Withdraw(shares, owner, receiver, msg.sender, assets)
	log TrackSharePrice(share_price, share_price, self._get_share_APR())

	return shares


@internal
def _update_shares(_assets: uint256, _impair: bool = False) -> (uint256, uint256):
	"""
	@return diff in APR, diff in owner fees
	"""
	init_share_price: uint256 = self._get_share_price()

	if not _impair:
		# correct current share price and distributed dividends before updating share valuation
		self._unlock_profits()

		self.total_assets += _assets
		self.locked_profit += _assets
		# start accruing on new locked profits

		return (_assets, 0)
	else:
		fees_burned: uint256 = 0

		# If available, take performance fee from delegate to offset impairment and protect depositors
		if self.accrued_fees >= _assets:
			fees_burned = _assets / init_share_price
		else:
			# else take what we can from delegate and socialize losses
			fees_burned = self.accrued_fees

		# burn delegate shares at pre-loss prices
		# TODO use post-loss price? delegate would lose more fees
		self._burn(self.owner, fees_burned, fees_burned * init_share_price)
		# reducing supply during impairment means share price goes UP
		self.accrued_fees -= fees_burned

		# TODO if changing delegate burn price, use same price for asset_diff
		pool_assets_lost: uint256 = _assets - (fees_burned * init_share_price)

		# TODO TEST - analyze delegate attack vector. 
		# scenario = pool has bad debt. delegate wants to realize all pool losses while minimizing thier fees burned
		# 1. delegate calls impair from a non-self.owner address
		# 2. delegate fees are burned.
		# 3. Share price increases.
		# 4. Delegate receives 30% of shares as raw asset
		# 5. Delegate sends asset back to pool
		# 6. Share price increases again
		# 7. Delegate can now withdraw X% more fees than if attack hadnt happened.

		if pool_assets_lost != 0:
			# delegate fees not enough to eat losses. Socialize the plebs

			# Auto dump on current pool holders. share price immediately falls
			# NOTE: impair() is neutral but divest4626() is controlled by delegate.
			# They can claim_fees and then force pool losses
			self.total_assets -= pool_assets_lost

			# Profit is locked and gradually released per block
			# NOTE: compute current locked profit and replace with sum of current and new
			locked_profit_before_loss: uint256 = self._calc_locked_profit() 

			# TODO Keep locked profit the same and immediately reduce share price?
			# need to be able to gradually go up AND down in share price but i dont think this covers that
			# 
			# add amoritized_loss in addition to locked_profit ?
			if locked_profit_before_loss >= pool_assets_lost: 
				self.locked_profit = locked_profit_before_loss - pool_assets_lost
			else:
				self.locked_profit = 0
		
		# correct current share price and distributed dividends after eating losses
		self._unlock_profits()

		return (pool_assets_lost, fees_burned)


	# log price change after updates
	# TODO check that no calling functions also emit 
	log TrackSharePrice(init_share_price, self._get_share_price(), self._get_share_APR())

@internal
def _unlock_profits() -> uint256:
	profits: uint256 = self._calc_locked_profit()


	# TODO RDT logic
	return 0

@view
@internal
def _get_share_price() -> uint256:
	"""
	@notice
		uses outstanding shares (liabilities) with total assets held in vault to calculate price per share
	@dev
		_locked_profit is totally separate from _get_share_price
	@return
		# of assets per share. denominated in pool/asset decimals (MUST be the same)
	"""
	# no share price if nothing minted/deposited
	if self.total_supply == 0 or self.total_assets == 0:
		return 0

	return (self.total_assets - self._calc_locked_profit()) / self.total_supply

@view
@internal
def _get_share_APR() -> int256:
	# returns rate of share price increase/decrease
	# TODO RDT logic
	return 0

@view
@internal
def _calc_locked_profit() -> uint256:
    pct_profit_locked: uint256 = (block.timestamp - self.last_report) * self.locked_profit_degradation

    if(pct_profit_locked < DEGRADATION_COEFFICIENT):
        locked_profit: uint256 = self.locked_profit
        return locked_profit - (
                pct_profit_locked
                * locked_profit
                / DEGRADATION_COEFFICIENT
            )
    else:        
        return 0


@view
@internal
def _get_max_liquid_assets() -> uint256:
	return self.total_assets - self.total_deployed - self._calc_locked_profit()

@pure
@internal
def _get_pool_name(_name: String[34]) -> String[50]:
	return concat(CONTRACT_NAME, ' - ', _name)

@pure
@internal
def _get_pool_symbol(_asset: address, _symbol: String[9]) -> String[18]:
	"""
	@dev 		 		if we dont directly copy the `asset`'s decimals then we need to do decimal conversions everytime we calculate share price
	@param _symbol	 	custom symbol input by pool creator
	@return 			e.g. ddpDAI-LLAMA, ddpWETH-KARPATKEY
	"""
	sym: String[5] = slice(IERC20Detailed(_asset).symbol(), 0, 5)
	return concat("ddp", sym, '-', _symbol)

@pure
@internal
def _get_pool_decimals(_token: address) -> uint8:
	"""
	@dev 		 		if we dont directly copy the `asset`'s decimals then we need to do decimal conversions everytime we calculate share price
	@param _token 		pool's asset to mimic decimals for pool's token
	"""
	success: bool = False
	asset_decimals: Bytes[8] = b""
	success, asset_decimals = raw_call(
		_token,
		_abi_encode(b"",method_id=method_id("decimals()")),
		max_outsize=8,
		is_static_call=True,
		revert_on_failure=False
	)

	if success:
		return convert(asset_decimals, uint8)
	else:
		return 18


# 	 IERC 3156 Flash Loan functions
# 
#                    .-~*~--,.   .-.
#           .-~-. ./OOOOOOOOO\.'OOO`9~~-.
#         .`OOOOOO.OOM.OLSONOOOOO@@OOOOOO\
#        /OOOO@@@OO@@@OO@@@OOO@@@@@@@@OOOO`.
#        |OO@@@WWWW@@@@OOWWW@WWWW@@@@@@@OOOO).
#      .-'OO@@@@WW@@@W@WWWWWWWWOOWW@@@@@OOOOOO}
#     /OOO@@O@@@@W@@@@@OOWWWWWOOWOO@@@OOO@@@OO|
#    lOOO@@@OO@@@WWWWWWW\OWWWO\WWWOOOOOO@@@O.'
#     \OOO@@@OOO@@@@@@OOW\     \WWWW@@@@@@@O'.
#      `,OO@@@OOOOOOOOOOWW\     \WWWW@@@@@@OOO)
#       \,O@@@@@OOOOOOWWWWW\     \WW@@@@@OOOO.'
#         `~c~8~@@@@WWW@@W\       \WOO|\UO-~'
#              (OWWWWWW@/\W\    ___\WO)
#                `~-~''     \   \WW=*'
#                          __\   \
#                          \      \
#                           \    __\
#                            \  \
#                             \ \
#                              \ \
#                               \\
#                                \\
#                                 \
#                                  \
#

@view
@external
def maxFlashLoan(_token: address) -> uint256:
	if _token != asset:
		return 0
	else:
		return self._get_max_liquid_assets()

@view
@internal
def _get_flash_fee(_token: address, _amount: uint256) -> uint256:
	"""
	@notice slight wrapper _calc_fee to account for liquid assets that can be lent
	"""
	if self.fees.flash == 0:
		return 0
	else:
		return self._calc_fee(min(_amount, self._get_max_liquid_assets()), self.fees.flash)

@view
@external
def flashFee(_token: address, _amount: uint256) -> uint256:
	assert _token == asset
	return self._get_flash_fee(_token, _amount)

@external
@nonreentrant("lock")
def flashLoan(
	receiver: address,
	_token: address,
	amount: uint256,
	data: Bytes[25000]
) -> bool:
	assert amount <= self._get_max_liquid_assets()

	# give them the flashloan
	self._erc20_safe_transfer(asset, msg.sender, amount)

	fee: uint256 = self._get_flash_fee(_token, amount)
	
	# ensure they can receive flash loan
	# TODO says onFlashLoan not on interface
	assert IERC3156FlashBorrower(receiver).onFlashLoan(msg.sender, _token, amount, fee, data) == keccak256("ERC3156FlashBorrower.onFlashLoan")
	
	# receive payment
	IERC20(asset).transferFrom(msg.sender, self, amount + fee)

	self._update_shares(fee)

	log FeesGenerated(msg.sender, self, fee, amount, FEE_TYPES.FLASH)

	return True

# EIP712 permit functionality

@pure
@external
def apiVersion() -> String[28]:
	"""
	@notice
		Used to track the deployed version of this contract. In practice you
		can use this version number to compare with Debt DAO's GitHub and
		determine which version of the source matches this deployed contract.
	@dev
		All strategies must have an `apiVersion()` that matches the Vault's
		`API_VERSION`.
	@return API_VERSION which holds the current version of this contract.
	"""
	return API_VERSION

@view
@internal
def domain_separator() -> bytes32:
	return keccak256(
		concat(
			DOMAIN_TYPE_HASH,
			keccak256(convert(CONTRACT_NAME, Bytes[18])),
			keccak256(convert(API_VERSION, Bytes[18])),
			convert(chain.id, bytes32),
			convert(self, bytes32)
		)
	)

@view
@external
def DOMAIN_SEPARATOR() -> bytes32:
	if chain.id == CACHED_CHAIN_ID:
		return CACHED_COMAIN_SEPARATOR
	else:
		return self.domain_separator()

@nonpayable
@external
def permit(owner: address, spender: address, amount: uint256, deadline: uint256, signature: Bytes[65]) -> bool:
	"""
	@notice
		Approves spender by owner's signature to expend owner's tokens.
		See https://eips.ethereum.org/EIPS/eip-2612.
		Stolen from Yearn Vault code
		https://github.com/yearn/yearn-vaults/blob/74364b2c33bd0ee009ece975c157f065b592eeaf/contracts/Vault.vy#L765-L806
	@param owner The address which is a source of funds and has signed the Permit.
	@param spender The address which is allowed to spend the funds.
	@param amount The amount of tokens to be spent.
	@param deadline The timestamp after which the Permit is no longer valid.
	@param signature A valid secp256k1 signature of Permit by owner encoded as r, s, v.
	@return True, if transaction completes successfully
	"""
	assert owner != empty(address)  # dev: invalid owner
	assert deadline >= block.timestamp  # dev: permit expired

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
					convert(deadline, bytes32),
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


# IERC20 view functions

@view
@external
def name() -> String[50]:
    return NAME


@view
@external
def symbol() -> String[18]:
    return SYMBOL


@view
@external
def decimals() -> uint8:
    return DECIMALS

@external
@view
def balanceOf(account: address) -> uint256:
	return self.balances[account]

@external
@view
def allowance(owner: address, spender: address) -> uint256:
	return self.allowances[owner][spender]

# IERC4626 view functions

@view
@external
def totalAssets() -> uint256:
	return self.total_assets

@view
@external
def totalSupply() -> uint256:
	return self.total_supply

@view
@external
def APR() -> int256:
	return self._get_share_APR()

@view
@external
def price() -> uint256:
	return self._get_share_price()

@external
@view
def convertToShares(_assets: uint256) -> uint256:
	return _assets * (self.total_assets / self.total_supply)

@external
@view
def convertToAssets(_shares: uint256) -> uint256:
	return _shares * (self.total_supply / self.total_assets)

@external
@view
def maxDeposit(_receiver: address) -> uint256:
	"""
		add assets
	"""
	return max_value(uint256) - self.total_assets

@external
@view
def maxMint(_receiver: address) -> uint256:
	return (max_value(uint256) - self.total_assets) / self._get_share_price()

@external
@view
def maxWithdraw(_owner: address) -> uint256:
	"""
		remove shares
	"""
	return self._get_max_liquid_assets()


@external
@view
def maxRedeem(_owner: address) -> uint256:
	"""
		remove assets
	"""
	return self._get_max_liquid_assets() / self._get_share_price()

@external
@view
def previewDeposit(_assets: uint256) -> uint256:
	"""
	@notice		Returns max amount that can be deposited which is min(maxDeposit, userRequested)
				So if assets > maxDeposit then it returns maxDeposit
	@dev 		INCLUSIVE of deposit fees (should be same as without deposit fees bc of mintflation)
	@return 	shares returned when minting _assets
	"""
	share_price: uint256 =  self._get_share_price()
	free_shares: uint256 = min(max_value(uint256) - self.total_assets, _assets) / share_price
	# TODO Dont think we need to include fees here since they are inflationary they shouldnt affect return values
	return free_shares - self._calc_fee(_assets / share_price, self.fees.deposit)

@external
@view
def previewMint(_shares: uint256) -> uint256:
	"""
	@notice		Returns max amount that can be deposited which is min(maxDeposit, userRequested)
				So if assets > maxDeposit then it returns maxDeposit
	@dev 		INCLUSIVE of deposit fees (should be same as without deposit fees bc of mintflation)
	@return 	assets required to mint _shares
	"""
	share_price: uint256 =  self._get_share_price()
	free_shares: uint256 = min(max_value(uint256) - self.total_assets, _shares * share_price)
	# TODO Dont think we need to include fees here since they are inflationary they shouldnt affect return values
	return (free_shares - self._calc_fee(free_shares, self.fees.deposit)) * share_price

@external
@view
def previewWithdraw(_assets: uint256) -> uint256:
	share_price: uint256 =  self._get_share_price()
	free_shares: uint256 = min(self._get_max_liquid_assets(), (max_value(uint256) - _assets)) / share_price
	# TODO Dont think we need to include fees here since they are inflationary they shouldnt affect return values
	return free_shares - self._calc_fee(_assets / share_price, self.fees.withdraw)

@external
@view
def previewRedeem(_shares: uint256) -> uint256:
	share_price: uint256 =  self._get_share_price()
	free_shares: uint256 = min(self._get_max_liquid_assets(), _shares * share_price)
	# TODO Dont think we need to include fees here since they are inflationary they shouldnt affect return values
	return (free_shares - self._calc_fee(free_shares, self.fees.withdraw)) * share_price



### Pool view
@view
@external
def free_profit() -> uint256:
	"""
	@notice
		Amount of profit that can currently be vested into pool share price
	"""
	return self.locked_profit - self._calc_locked_profit()


@view
@external
def owned_assets() -> uint256:
	"""
	@notice
		Not ur keys, not ur coins.
		Includes all assets held within pool including locked_profits. 
		Excludes all assets deposited in external contracts
	@return
		Total amount of assets cryptographically owned by this contract
	"""
	return self.total_assets - self.total_deployed

@view
@external
def liquid_assets() -> uint256:
	"""
	@notice
		All available assets that can be withdrawn by depositors
	@return
		All available assets that can be withdrawn by depositors
	"""
	return self.total_assets - self.total_deployed - self._calc_locked_profit()





# 88                                            ad88                                   
# ""              ,d                           d8"                                     
#                 88                           88                                      
# 88 8b,dPPYba, MM88MMM ,adPPYba, 8b,dPPYba, MM88MMM ,adPPYYba,  ,adPPYba,  ,adPPYba,  
# 88 88P'   `"8a  88   a8P_____88 88P'   "Y8   88    ""     `Y8 a8"     "" a8P_____88  
# 88 88       88  88   8PP""""""" 88           88    ,adPPPPP88 8b         8PP"""""""  
# 88 88       88  88,  "8b,   ,aa 88           88    88,    ,88 "8a,   ,aa "8b,   ,aa  
# 88 88       88  "Y888 `"Ybbd8"' 88           88    `"8bbdP"Y8  `"Ybbd8"'  `"Ybbd8"'  




from vyper.interfaces import ERC20 as IERC20

interface IERC2612:
	# TODO: standard permit interface. Need to change yearn code for it.
    # def permit(owner: address, spender: address, amount: uint256, deadline: uint256, v: uint8, r: bytes32, s: bytes32) -> bool: nonpayable
    def permit(owner: address, spender: address, amount: uint256, deadline: uint256, signature: Bytes[65]) -> bool: nonpayable
    def nonces(owner: address ) -> uint256: view
    def DOMAIN_SEPARATOR() -> bytes32: view

interface IERC20Detailed: 
	def name() -> String[18]: view
	def symbol() -> String[18]: view
	def decimals() -> uint8: view

interface IERC4626:
    def deposit(assets: uint256, receiver: address)  -> uint256: nonpayable
    def withdraw(assets: uint256, receiver: address, owner: address) -> uint256: nonpayable
    def mint(shares: uint256, receiver: address) -> uint256: nonpayable
    def redeem(shares: uint256, receiver: address, owner: address) -> uint256: nonpayable

    # autogenerated state getters

    # def asset() -> address: view

	# manually generated getters

    # @notice total underlying assets owned by the pool 
    def totalAssets() -> uint256: view
    # @notice amount of shares that the Vault would exchange for the amount of assets provided
    def convertToShares(assets: uint256) -> uint256: view 
    # @notice amount of assets that the Vault would exchange for the amount of shares provided
    def convertToAssets(shares: uint256) -> uint256: view
    # @notice maximum amount of assets that can be deposited into vault for receiver
    def maxDeposit(receiver: address) -> uint256: view # @dev returns maxAssets
    # @notice simulate the effects of their deposit() at the current block, given current on-chain conditions.
    def previewDeposit(assets: uint256) -> uint256: view
    # @notice maximum amount of shares that can be deposited into vault for receiver
    def maxMint(receiver: address) -> uint256: view # @dev returns maxAssets
    # @notice simulate the effects of their mint() at the current block, given current on-chain conditions.
    def previewMint(shares: uint256) -> uint256: view
    # @notice maximum amount of assets that can be withdrawn into vault for receiver
    def maxWithdraw(receiver: address) -> uint256: view # @dev returns maxAssets
    # @notice simulate the effects of their withdraw() at the current block, given current on-chain conditions.
    def previewWithdraw(assets: uint256) -> uint256: view
    # @notice maximum amount of shares that can be withdrawn into vault for receiver
    def maxRedeem(receiver: address) -> uint256: view # @dev returns maxAssets
    # @notice simulate the effects of their redeem() at the current block, given current on-chain conditions.
    def previewRedeem(shares: uint256) -> uint256: view

# 4626 extension for referrals
interface IERC4626R:
    def depositWithReferral(assets: uint256, receiver: address, referrer: address)  -> uint256: nonpayable
    def mintWithReferral(shares: uint256, receiver: address, referrer: address) -> uint256: nonpayable

# 4626 extension for permits
interface IERC4626P:
    def depositWithPermit(assets: uint256, receiver: address, referrer: address)  -> uint256: nonpayable
    def mintWithPermit(shares: uint256, receiver: address, referrer: address) -> uint256: nonpayable
    def depositWithPermit2(assets: uint256, receiver: address, referrer: address)  -> uint256: nonpayable
    def mintWithPermit2(shares: uint256, receiver: address, referrer: address) -> uint256: nonpayable


# Flashloans
interface IERC3156:
    # /**
    # * @dev The amount of currency available to be lent.
    # * @param token The loan currency.
    # * @return The amount of `token` that can be borrowed.
    # */
    def maxFlashLoan(token: address) -> uint256: view

    # /**
    # * @dev The fee to be charged for a given loan.
    # * @param token The loan currency.
    # * @param amount The amount of tokens lent.
    # * @return The amount of `token` to be charged for the loan, on top of the returned principal.
    # */
    def flashFee(token: address, amount: uint256) -> uint256: view

    # /**
    # * @dev Initiate a flash loan.
    # * @param receiver The receiver of the tokens in the loan, and the receiver of the callback.
    # * @param token The loan currency.
    # * @param amount The amount of tokens lent.
    # * @param data Arbitrary data structure, intended to contain user-defined parameters.
    # */
    def flashLoan(
        receiver: address,
        token: address,
        amount: uint256,
        data: Bytes[25000]
    ) -> bool: payable


interface IERC3156FlashBorrower:
    def onFlashLoan(
        initiator: address,
        token: address,
        amount: uint256,
        fee: uint256,
        data:  Bytes[25000]
    ) -> bytes32: payable


# Debt DAO interfaces

interface ISecuredLine:
    def ids(index: uint256) -> bytes32: view
    def status() -> uint256: view
    def credits(id: bytes32) -> Position: view
    def available(id: bytes32) -> (uint256, uint256): view

	# invest
    def addCredit(
        drate: uint128,
        frate: uint128,
        amount: uint256,
        token: address,
        lender: address
    )-> bytes32: payable
    def setRates(id: bytes32, drate: uint128, frate: uint128) -> bool: nonpayable
    def increaseCredit(id: bytes32,  amount: uint256) -> bool: payable

    # self-repay
    def useAndRepay(amount: uint256) -> bool: nonpayable

    # divest
    def withdraw(id: bytes32,  amount: uint256) -> bool: nonpayable

# (uint256, uint256, uint256, uint256, uint8, address, address)
struct Position:
    deposit: uint256
    principal: uint256
    interestAccrued: uint256
    interestRepaid: uint256
    decimals: uint8
    token: address
    lender: address

### Events

# IERC20 Events
event Transfer:
	sender: indexed(address)
	receiver: indexed(address)
	value: uint256

event Approval:
	owner: indexed(address)
	spender: indexed(address)
	value: uint256

# IERC4626 Events
event Deposit:
	shares: indexed(uint256)
	owner: indexed(address)
	sender: address
	assets: uint256

event Withdraw:
	shares: indexed(uint256)
	owner: indexed(address)
	receiver: indexed(address)
	sender: address
	assets: uint256

# Pool Events
event TrackSharePrice:
	pre_op_price: uint256 	# price before doing pool actions and price updates 
	post_op_price: uint256 	# price after doing pool actions and price updates
	trans_change: int256 	# transitory change in share price denominated in APR bps. + for good boi, - for bad gurl

# Investing Events
event Impair:
	id: indexed(bytes32)
	recovered: indexed(uint256)
	lost: indexed(uint256)
	old_apr: int256
	new_apr: int256
	share_price: uint256
	fees_burned: uint256

event Invest4626:
	vault: indexed(address)
	assets: indexed(uint256)
	shares: indexed(uint256)

event Divest4626:
	vault: indexed(address)
	assets: indexed(uint256)
	shares: indexed(uint256)
	profit_loss: int256 # how many assets we realized as losses or gained (NOT YET realized) as profit when divesting

# fees
event UpdateFee:
	fee_bps: indexed(uint16)
	fee_type: indexed(FEE_TYPES)

event NewPendingFeeRecipient:
	newRecipient: address # New active management fee

event AcceptFeeRecipient:
	newRecipient: address # New active management fee

event FeesGenerated:
	payer: indexed(address)
	receiver: indexed(address)
	fee: indexed(uint256)
	shares: uint256 # total shares fees were generated on (interest, deposit, flashloan)
	feeType: FEE_TYPES # self.fees enum index

event OwnerFeeClaimed:
	recipient: indexed(address)
	fees: indexed(uint256)


# Admin updates

event NewPendingOwner:
	pendingOwner: indexed(address)

event UpdateOwner:
	owner: indexed(address) # New active governance

event UpdateMinDeposit:
	minimum: indexed(uint256) # New active deposit limit

event UpdateMaxAssets:
	maximum: indexed(uint256) # New active deposit limit

event Sweep:
	token: indexed(address) # New active deposit limit
	amount: indexed(uint256) # New active deposit limit

event UpdateProfitDegredation:
	degredation: indexed(uint256)
