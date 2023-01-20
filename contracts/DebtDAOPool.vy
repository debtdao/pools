# @version ^0.3.7

"""
@title 	Debt DAO Lending Pool
@author	Kiba Gateaux
@notice	Tokenized, liquid 4626 pool allowing depositors to collectively lend to Debt DAO Line of Credit contracts
@dev	All investment decisions and pool paramters are controlled by the pool owner aka "Delegate"



TODO - 
6. implement _get_share_APR()
10. Add performance fee to 4626 profits?
5. understand how DEGREDATION_COEFFICIENT works
11. add sepearet var from total_assets called total_debt and use that instead. Prevents lvg from fucking up share price. can incorporatedebt into share price if we want
8. should we call _unlock_profits on - deposit, withdraw, invest, divest?
1. Refactor yearn permit()  so args are exactly 2612 standard
2. Add permit + permit2 IERC4626P extension and implement functions
4. add dev: revert strings to all asserts
2. add IERC4626RP (referral + permit)
3. Make sure using appropriate instances of total_assets, total_deployed, liquid_assets, owned_assets, etc. in state updates and price algorithms
7. add more events around share price updates and other internal components
9. fix/mitigate rounding errors on share price. might need to make initial share price PRICE_DECIMALS
"""

# interfaces defined at bottom of file
implements: IERC20
implements: IERC2612
implements: IERC3156
implements: IERC4626
implements: IERC4626R
implements: IDebtDAOPool
implements: IRevenueGenerator


# this contracts interface for reference
interface IDebtDAOPool:
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
	def divest_vault(vault: address, amount: uint256) -> bool: nonpayable
	def invest_vault(vault: address, amount: uint256) -> uint256: nonpayable

	# Pool Admin
	def set_max_assets(new_max: uint256) -> bool: nonpayable
	def set_min_deposit(new_min: uint256) -> bool: nonpayable
	def set_profit_degredation(vesting_rate: uint256): nonpayable

	# fees
	def set_performance_fee(fee: uint16) -> bool: nonpayable
	def set_collector_fee(fee: uint16) -> bool: nonpayable
	def set_withdraw_fee(fee: uint16) -> bool: nonpayable
	def set_deposit_fee(fee: uint16) -> bool: nonpayable
	def set_flash_fee(fee: uint16) -> bool: nonpayable


### Constants
### TODO only making public for testing purposes. ideally could remain private but still have easy access from tests

# @notice LineLib.STATUS.INSOLVENT
INSOLVENT_STATUS: public(constant(uint256)) = 4
# @notice LineLib.STATUS.REPAID
REPAID_STATUS: public(constant(uint256)) = 3
# @notice 100% in bps. Used to divide after multiplying bps fees. Also max performance fee.
FEE_COEFFICIENT: public(constant(uint16)) = 10000
# @notice 30% in bps. snitch gets 1/3  of owners fees when liquidated to repay impairment.
# IF owner fees exist when snitched on. Pool depositors are *guaranteed* to see a price increase, hence heavy incentive to snitches.
SNITCH_FEE: public(constant(uint16)) = 3000
# @notice 5% in bps. Max fee that can be charged for non-performance fee
MAX_PITTANCE_FEE: public(constant(uint16)) = 200
# @notice EIP712 contract name
CONTRACT_NAME: public(constant(String[13])) = "Debt DAO Pool"
# @notice EIP712 contract version
API_VERSION: public(constant(String[7])) = "0.0.001"
# @notice EIP712 type hash
DOMAIN_TYPE_HASH: public(constant(bytes32)) = keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
# @notice EIP712 permit type hash
PERMIT_TYPE_HASH: public(constant(bytes32)) = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
# TODO rename DEGRADATION_COEFFICIENT
# rate per block of profit degradation. DEGRADATION_COEFFICIENT is 100% per block
DEGRADATION_COEFFICIENT: public(constant(uint256)) = 10 ** 18

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
ASSET: public(immutable(address))
# total notional amount of underlying token owned by pool (may not be currently held in pool)
total_assets: public(uint256)

# share price logic stolen from yearn vyper vaults
# vars - https://github.com/yearn/yearn-vaults/blob/74364b2c33bd0ee009ece975c157f065b592eeaf/contracts/Vault.vy#L239-L242
last_report: public(uint256) 	# block.timestamp of last report
locked_profit: public(uint256) 	# how much profit is locked and cant be withdrawn
# lower the coefficient the slower the profit drip
vesting_rate: public(uint256) # The rate of degradation in percent per second scaled to 1e18.  DEGRADATION_COEFFICIENT is 100% per block

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
rev_recipient: public(address)
# address to migrate revenuestream to. Must be accepted before transfer occurs
pending_rev_recipient: public(address)
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
	assert _delegate != empty(address), "must have delegate"

	self.owner = msg.sender # set owner to deployer for validation functions
	self._assert_max_fee(_fees.performance, FEE_TYPES.PERFORMANCE) # max 100% performance fee
	self._assert_pittance_fee(_fees.collector, FEE_TYPES.COLLECTOR)
	self._assert_pittance_fee(_fees.flash, FEE_TYPES.FLASH)
	self._assert_pittance_fee(_fees.referral, FEE_TYPES.REFERRAL)
	self._assert_pittance_fee(_fees.deposit, FEE_TYPES.DEPOSIT)
	self._assert_pittance_fee(_fees.withdraw, FEE_TYPES.WITHDRAW)

	# Setup Pool variables
	self.fees = _fees
	self.owner = _delegate
	self.allowances[self][_delegate] = max_value(uint256) # allow owner to take fees
	self.rev_recipient = _delegate
	self.max_assets = max_value(uint256)

	# IERC20 vars
	NAME = self._get_pool_name(_name)
	SYMBOL = self._get_pool_symbol(_asset, _symbol)
	# MUST use same decimals as `asset` token. revert if call fails
	# We do not account for differening token decimals in our math
	DECIMALS = IERC20Detailed(_asset).decimals()
	assert DECIMALS != 0, "bad decimals" # 0 could be non-standard `False` or revert

	# IERC4626
	ASSET = _asset

	# NOTE: Yearn - set profit to be distributed every 6 hours
	# self.vesting_rate = convert(DEGRADATION_COEFFICIENT * 46 / 10 ** 6 , uint256)

	# TODO: Debt DAO - set profit to bedistributed to every `1 eek` (ethereum week)
	# 2048 epochs = 2048 blocks = COEFFICIENT / 2048 / 10 ** 6 ???
	self.vesting_rate = convert(DEGRADATION_COEFFICIENT * 46 / 10 ** 6 , uint256)
	self.last_report = block.timestamp

	# IERC2612
	CACHED_CHAIN_ID = chain.id # cache before compute
	CACHED_COMAIN_SEPARATOR = self.domain_separator()


### Investing functions

@internal
def _assert_delegate_has_available_funds(amount: uint256):
	assert msg.sender == self.owner, "not owner"
	assert self.total_assets - self.total_deployed >= amount

@external
@nonreentrant("lock")
def add_credit(_line: address, _drate: uint128, _frate: uint128, _amount: uint256) -> bytes32:
	self._assert_delegate_has_available_funds(_amount)
	 # prevent delegate confusion btw this add_credit and accept_offer which also call SecuredLine.addCredit()
	assert ISecuredLine(_line).borrower() != self
	
	self.total_deployed += _amount
	
	# NOTE: no need to log, Line emits events already
	return ISecuredLine(_line).addCredit(_drate, _frate, _amount, ASSET, self)

@external
@nonreentrant("lock")
def increase_credit(line: address, id: bytes32, amount: uint256) -> bool:
	self._assert_delegate_has_available_funds(amount)

	self.total_deployed += amount

	# NOTE: no need to log, Line emits events already
	return ISecuredLine(line).increaseCredit(id, amount)

@external
def set_rates(line: address, id: bytes32, drate: uint128, frate: uint128) -> bool:
	assert msg.sender == self.owner, "not owner"
	# NOTE: no need to log, Line emits events already
	return ISecuredLine(line).setRates(id, drate, frate)

@external
@nonreentrant("lock")
def collect_interest(line: address, id: bytes32) -> uint256:
	"""
	@notice
		Anyone can claim interest from active lines and start vesting profits into pool shares
	@return
		Amount of assets earned in Debt DAO Line of Credit contract
	"""
	return self._reduce_credit(line, id, 0)[1]

@external
@nonreentrant("lock")
def abort(line: address, id: bytes32) -> (uint256, uint256):
	"""
	@notice emergency cord to remove all avialable funds from a line (deposit + interestRepaid)
	"""
	assert msg.sender == self.owner, "not owner"
	return self._reduce_credit(line, id, max_value(uint256))

@external
@nonreentrant("lock")
def reduce_credit(line: address, id: bytes32, amount: uint256) -> (uint256, uint256):
	assert msg.sender == self.owner, "not owner"
	return self._reduce_credit(line, id, amount)

@external
@nonreentrant("lock")
def use_and_repay(line: address, repay: uint256, withdraw: uint256) -> (uint256, uint256):
	assert msg.sender == self.owner, "not owner"

	# Assume we are next lender in queue. 
	# save id for later incase we repay full amount and stepQ
	id: bytes32 = ISecuredLine(line).ids(0)

	# NOTE: no need to log, Line emits events already
	assert ISecuredLine(line).useAndRepay(repay)

	return self._reduce_credit(line, id, withdraw)

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
def invest_vault(_vault: address, _amount: uint256) -> uint256:
	self._assert_delegate_has_available_funds(_amount)

	self.total_deployed += _amount
	self.vault_investments[_vault] += _amount

	# NOTE: Delegate should check previewDeposit(`_amount`) expected vs `_amount` for slippage ?
	shares: uint256 = IERC4626(_vault).deposit(_amount, self)

	log InvestVault(_vault, _amount, shares) ## TODO shares
	return shares


@external
@nonreentrant("lock")
def divest_vault(_vault: address, _amount: uint256) -> bool:
	is_loss: bool = False
	net: uint256 = 0
	(is_loss, net) = self._divest_vault(_vault, _amount)

	if not is_loss:
		# if not snitching, then only owner can call bc its part of their investment strategy
		# otherwise if is_loss anyone can snitch to burn delegate fees and recoup pool losses
		assert msg.sender == self.owner

	# TODO TEST check that investing, then partially divesting at a loss, then investing more, then divesting more at a profit and/or loss updates our pool share price appropriately

	return True


@external
def sweep(_token: address, _amount: uint256 = max_value(uint256)):
	"""
	@notice
		Removes tokens from this Vault that are not the type of token managed
		by this Vault. This may be used in case of accidentally sending the
		wrong kind of token to this Vault.
		Tokens will be sent to `governance`.
		This will fail if an attempt is made to sweep the tokens that this
		Vault manages.
		This may only be called by governance.
	@param _token The token to transfer out of this vault.
	@param _amount The quantity or tokenId to transfer out.
	"""
	assert msg.sender == self.owner, "not owner"

	value: uint256 = _amount
	if _token == ASSET:
		# recover assets sent directly to pool
		# Can't be used to steal what this Vault is protecting
		value = IERC20(ASSET).balanceOf(self) - (self.total_assets - self.total_deployed)
	elif _token == self:
		# recover shares sent directly to pool, minus fees held for owner.
		value = self.balances[self] - self.accrued_fees
	elif value == max_value(uint256):
		value = IERC20(_token).balanceOf(self)

	log Sweep(_token, value)
	self._erc20_safe_transfer(_token, self.owner, value)


### Pool Admin

@external
def set_owner(new_owner: address) -> bool:
	assert msg.sender == self.owner, "not owner"
	self.pending_owner = new_owner
	log NewPendingOwner(new_owner)
	return True

@external
def accept_owner() -> bool:
	new_owner: address = self.pending_owner
	assert msg.sender == new_owner
	self.allowances[self][self.owner] = 0 # disallow old owner to claim fees
	self.owner = new_owner
	self.allowances[self][new_owner] = max_value(uint256) # allow owner to take fees
	log UpdateOwner(new_owner)
	return True

# THS IS COOL^

@external
def set_min_deposit(new_min: uint256)  -> bool:
	assert msg.sender == self.owner, "not owner"
	self.min_deposit = new_min
	log UpdateMinDeposit(new_min)
	return True

@external
def set_max_assets(new_max: uint256)  -> bool:
	assert msg.sender == self.owner, "not owner"
	self.max_assets = new_max
	log UpdateMaxAssets(new_max)
	return True


### Manage Pool Fees

@internal
def _assert_max_fee(fee: uint16, fee_type: FEE_TYPES) -> bool:
  assert msg.sender == self.owner, "not owner"
  assert fee <= FEE_COEFFICIENT, "bad performance fee" # max 100% performance fee
  log UpdateFee(fee, fee_type)
  return True

@external
@nonreentrant("lock")
def set_performance_fee(fee: uint16) -> bool:
  self.fees.performance = fee
  return self._assert_max_fee(fee, FEE_TYPES.PERFORMANCE)

@internal
def _assert_pittance_fee(fee: uint16, fee_type: FEE_TYPES) -> bool:
	assert msg.sender == self.owner, "not owner"
	assert fee <= MAX_PITTANCE_FEE, "bad pittance fee"
	log UpdateFee(fee, fee_type)
	return True

@external
@nonreentrant("lock")
def set_flash_fee(fee: uint16) -> bool:
	self.fees.flash = fee
	return self._assert_pittance_fee(fee, FEE_TYPES.FLASH)

@external
@nonreentrant("lock")
def set_collector_fee(fee: uint16) -> bool:
	self.fees.collector = fee
	return self._assert_pittance_fee(fee, FEE_TYPES.COLLECTOR)

@external
@nonreentrant("lock")
def set_deposit_fee(fee: uint16) -> bool:
	self.fees.collector = fee
	return self._assert_pittance_fee(fee, FEE_TYPES.DEPOSIT)

@external
@nonreentrant("lock")
def set_withdraw_fee(fee: uint16) -> bool:
	self.fees.collector = fee
	return self._assert_pittance_fee(fee, FEE_TYPES.WITHDRAW)

@external
def set_rev_recipient(new_recipient: address) -> bool:
  assert msg.sender == self.rev_recipient
  self.pending_rev_recipient = new_recipient
  log NewPendingRevRecipient(new_recipient)
  return True

@external
def accept_rev_recipient() -> bool:
  assert msg.sender == self.pending_rev_recipient
  self.rev_recipient = msg.sender
  log AcceptRevRecipient(msg.sender)
  return True

@external
@nonreentrant("lock")
def claimable_rev(_token: address) -> uint256:
	if _token != self:
		return 0
	else:
		return self.accrued_fees

@external
@nonreentrant("lock")
def claim_rev(_token: address, _amount: uint256) -> bool:
	"""
	@param _token - token earned as fees to claim. NOTE: not used because `self` is hardcoded
	@param _amount - amount of _token rev_recipient wants to claim
	"""
	assert msg.sender == self.rev_recipient
	
	# set amount to claim
	claimed: uint256 = _amount
	if _amount == max_value(uint256):
		claimed = self.accrued_fees # set to max available
	
	# transfer fee shares locked in pool to fee recipient
	self.accrued_fees -= claimed
	self._transfer(self, msg.sender, claimed)

	log FeesClaimed(self.rev_recipient, claimed)
	# log price for product analytics
	price: uint256 = self._get_share_price()
	log TrackSharePrice(price, price, self._get_share_APR())

	return True

@external
@nonreentrant("lock")
def set_profit_degredation(_vesting_rate: uint256):
	"""
	@notice
		Changes the locked profit _vesting_rate.
	@param _vesting_rate The rate of _vesting_rate in percent per second scaled to 1e18.
	"""
	assert msg.sender == self.owner, "not owner"
	# Since "_vesting_rate" is of type uint256 it can never be less than zero
	assert _vesting_rate <= DEGRADATION_COEFFICIENT
	self.vesting_rate = _vesting_rate
	log UpdateProfitDegredation(_vesting_rate) 

###################################
###################################
##### DANGER PONZINOMICS ZONE #####
###################################
###################################


@external
@nonreentrant("lock")
def accept_offer(_line: address, _drate: uint128, _frate: uint128, _amount: uint256) -> bytes32:
	 # ensure can only call on Lines where we are borrower
	assert ISecuredLine(_line).borrower() == self
	
	# NOTE: no need to log, Line emits events already
	return ISecuredLine(_line).addCredit(_drate, _frate, _amount, ASSET, self)


@external
@nonreentrant("lock")
def borrow(_line: address, _id: bytes32, _amount: uint256):
	"""
	@notice allows pool delegate to borrow and lever up / earn spread

	TODO should we more tightly integrate LoC in? I like having it loosely coupled, makes it kinda automagic
		 also adds security risk but less than giving full control of ur asset to Delegate
	"""
	assert msg.sender == self.owner

	# checkpoint our balance to make sure we receive the money we want
	pre_balance: uint256 = IERC20(ASSET).balanceOf(self)

	ISecuredLine(_line).borrow(_id, _amount)

	post_balance: uint256 = IERC20(ASSET).balanceOf(self)

	assert pre_balance + _amount == post_balance
	self.total_assets += _amount
	# self.debt_owed += _amount


@external
@nonreentrant("lock")
def repay_debt(_line: address, _amount: uint256):
	"""
	@notice allows pool delegate to borrow and lever up / earn spread

	TODO should we more tightly integrate LoC in? I like having it loosely coupled, makes it kinda automagic
		 also adds security risk but less than giving full control of ur asset to Delegate
	"""	
	assert self == ISecuredLine(_line).borrower()
	assert REPAID_STATUS != ISecuredLine(_line).status()
	
	# TODO add conditional on line status. if DEFAUL or INSOLVENT then earn snitch fee
	# TODO could also check nextInQ dRate vs self.get_share_APR() and auto repay if one is +- the other
	# assert msg.sender == self.owner

	# checkpoint our balance to make sure we only pay what we expected
	# TODO balance check necessary on repayment if we are borrower and can only borrower asset? Assumes trust in the contract
	pre_balance: uint256 = IERC20(ASSET).balanceOf(self)
	
	IERC20(ASSET).approve(_line, _amount)
	assert ISecuredLine(_line).depositAndRepay(_amount)

	post_balance: uint256 = IERC20(ASSET).balanceOf(self)
	
	assert pre_balance - _amount == post_balance
	self.total_assets -= _amount
	# self.debt_owed -= _amount


####################################
####################################
##### LEAVING PONZINOMICS ZONE #####
####################################
####################################


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
	IERC2612(ASSET).permit(msg.sender, self, _assets, deadline, signature)
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
	return self._transfer(sender, receiver, amount)


@external
def approve(spender: address, amount: uint256) -> bool:
	self.allowances[msg.sender][spender] = amount
	log Approval(msg.sender, spender, amount)
	return True

@external
def increaseAllowance(_spender: address, _amount: uint256) -> bool:
	newApproval: uint256 = self.allowances[msg.sender][_spender] + _amount
	self.allowances[msg.sender][_spender] = newApproval
	log Approval(msg.sender, _spender, newApproval)
	return True


### Internal Functions 

# transfer + approve vault shares
@internal
def _transfer(_sender: address, _receiver: address, _amount: uint256) -> bool:
	# cant block transfer to self bc then we cant store fes for delegate
	# prevent locking funds and yUSD/CREAM style share price attacks
	# assert _receiver != self # dev: cant transfer to self

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

@internal
def _assert_caller_has_approval(_owner: address, _amount: uint256) -> bool:
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
def _erc20_safe_transfer(_token: address, _receiver: address, _amount: uint256):
	# Used only to send tokens that are not the type managed by this Vault.
	# HACK: Used to handle non-compliant tokens like USDT
	response: Bytes[32] = raw_call(
		_token,
		concat(
			method_id("transfer(address,uint256)"),
			convert(_receiver, bytes32),
			convert(_amount, bytes32),
		),
		max_outsize=32,
		revert_on_failure=True
	)
	if len(response) > 0:
		assert convert(response, bool), "Transfer failed!"


# 4626 + Pool internal functions

# inflate supply to take fees. reduce share price. tax efficient.


@internal
def _mint(_to: address, _shares: uint256, _assets: uint256) -> bool:
	"""
	@notice
		Inc internal supply with new assets deposited and shares minted
	"""
	self.total_assets += _assets
	self.total_supply += _shares
	self._transfer(empty(address), _to, _shares)
	return True

@internal
def _burn(owner: address, _shares: uint256, _assets: uint256) -> bool:
	"""
	"""
	self.total_assets -= _assets
	self.total_supply -= _shares
	self._transfer(owner, empty(address), _shares)
	return True

@internal
def _calc_and_mint_fee(
	payer: address,
	to: address,
	shares: uint256,
	fee: uint16,
	fee_type: FEE_TYPES
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
	log RevenueGenerated(payer, self, fees, shares, fee_type, to)
		
	return fees


@internal
@pure
def _calc_fee(shares: uint256, fee: uint16) -> uint256:
	"""
	@dev	does NOT emit `log RevenueGenerated` like _mint_and_calc. Must manuualy log if using this function whil changing state
	"""
	if fee == 0:
		return 0
	else:
		return (shares * convert(fee, uint256)) / convert(FEE_COEFFICIENT, uint256)

@internal 
def _divest_vault(_vault: address, _amount: uint256) -> (bool, uint256):
	"""
	@notice
		Anyone can divest entire vault balance as soon as a potential loss appears due to snitch incentive.
		This automatically protects pool depositors from staying in bad investments in liquid vaults unlike Lines where we can't clawback as easily.
		On the otherhand Lines give Delegates more control over the investment process + additional incentives via performance fee.

		Good dynamic where Lines have higher yield to fill accrued_fees but lower liquidity / capacity (high risk, high reward) so Delegate overflows to 4626 investments.
		4626 is more liquid, goes straight to users w/o fees, and has better snitch protections (low risk, low reward).
	@returns
		bool - if we realized profit or not
		uint256 - profit withdrawn (in assets)
	@dev
		We always reduce oustanding principal deposited in vault to 0 and then all withdrawals add to profit.
	"""
	is_loss: bool = True # optimistic pessimism
	net: uint256 = 0	 # yay?
	curr_shares: uint256 = IERC20(_vault).balanceOf(self)
	principal: uint256 = self.vault_investments[_vault] # MAY be a 0 but thats OK 👍

	if principal == 0 and curr_shares == 0: # nothing to withdraw
		return (is_loss, net) # technically no profit. 0 is cheaper to check too.

	amount: uint256 = _amount
	if _amount == 0:
		amount = principal
	if _amount == max_value(uint256):
		amount = IERC4626(_vault).previewWithdraw(_amount)

	burned_shares: uint256 = IERC4626(_vault).withdraw(amount, self, self)
	# assert burned_shares == expected_burn # ensure we are exiting at price we expect

	# calculate if we are realizing losses on vault investment
	# MUST ONLY be true when burning last share with outstanding principal left
	is_loss = curr_shares == burned_shares and principal > amount

	if is_loss:
		net = principal - amount
		self.vault_investments[_vault] = 0 # erase debt so no replay attacks
		# TODO calculate asset/share price slippage even if # shares are expected 
		# make sure we arent creating the loss ourselves by withdrawing too much at once
		self._update_shares(net, True)
	elif amount > principal:
		# withdrawing profit (+ maybe principal if != 0)
		# TODO TEST that this math works fine if principal == 0 and its pure profit from the start or if its profit + principal
		is_loss = False
		net = amount - principal
		self._update_shares(net) # add to locked_profit
		self.total_deployed -= principal
		self.vault_investments[_vault] = 0
		# NOTE: delegate doesnt earn fees on 4626 strategies to incentivize line investment
	else:
		# only recouping initial deposit, principal > amount
		is_loss = False
		self.total_deployed -= amount
		self.vault_investments[_vault] -= amount

	log DivestVault(_vault, amount, burned_shares, net, is_loss)

	return (is_loss, net)


@internal 
def _reduce_credit(line: address, id: bytes32, amount: uint256) -> (uint256, uint256):
	"""
	@notice		withdraw deposit and/or interest from an external position
	@return 	(initial principal withdrawn, interest earned)
	"""
	withdrawable: uint256 = amount
	interest: uint256 = 0
	deposit: uint256 = 0
	(deposit, interest) = ISecuredLine(line).available(id)

	if amount == 0:
		# 0 is shorthand for take maximum amount of interest
		withdrawable = interest
	elif amount == max_value(uint256):
		# MAX is shorthand for take all liquid assets
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
	
	if deposit != 0:
		self.total_deployed -= deposit # return principal to liquid pool

	if interest != 0:
		self._update_shares(interest) # add to locked profits
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
	@param interest_earned - total amount of assets claimed as interest payments from Debt DAO Line of Credit contracts
	@return total amount of shares taken as fees
	"""
	share_price: uint256 = self._get_share_price()
	shares_earned: uint256 = interest_earned / share_price

	performance_fee: uint256 = self._calc_and_mint_fee(self, self.owner, shares_earned, self.fees.performance, FEE_TYPES.PERFORMANCE)

	collector_fee: uint256 = self._calc_fee(shares_earned, self.fees.collector)
	if (collector_fee != 0 and msg.sender != self.owner): # lazy eval saves SLOAD
		# NOTE: only _calc not _mint_and_calc so caller gets collector fees in raw asset for easier MEV
		# NOTE: use pre performance fee inflation price for payout
		collector_assets: uint256 = collector_fee * share_price
		self.total_assets -= collector_assets
		self._erc20_safe_transfer(ASSET, msg.sender, collector_assets)
		log RevenueGenerated(self, ASSET, collector_assets, interest_earned, FEE_TYPES.COLLECTOR, msg.sender)

	return performance_fee + collector_fee


@internal
def _deposit(
	_assets: uint256,
	_receiver: address,
	_referrer: address = empty(address)
) -> uint256:
	"""
	adds shares to a user after depositing into vault
	priviliged internal func
	"""
	assert _assets >= self.min_deposit # dev: fuck plebs
	assert self.total_assets + _assets <= self.max_assets # dev: Pool max reached
	
	share_price: uint256 = self._get_share_price()
	shares: uint256 = _assets / share_price

	if self.fees.deposit != 0:
		self._calc_and_mint_fee(_receiver, self.owner, shares, self.fees.deposit, FEE_TYPES.DEPOSIT)

	if _referrer != empty(address) and self.fees.referral != 0:
		self._calc_and_mint_fee(_receiver, _referrer, shares, self.fees.referral, FEE_TYPES.REFERRAL)

	# TODO TEST how  deposit/refer fee inflatino affects the shares/asssets that they are *supposed* to lose

	# use original price, opposite of _withdraw, requires them to deposit more _assets than current price post fee inflation
	self._mint(_receiver, shares, _assets)

	assert IERC20(ASSET).transferFrom(msg.sender, self, _assets) # dev: asset.transferFrom() failed on deposit

	log Deposit(shares, _receiver, msg.sender, _assets)
	# log price change after deposit and fee inflation
	log TrackSharePrice(share_price, self._get_share_price(), self._get_share_APR())

	return shares

@internal
def _withdraw(
	_assets: uint256,
	_owner: address,
	_receiver: address
) -> uint256:
	assert _assets <= self._get_max_liquid_assets() 	# dev: insufficient liquidity

	share_price: uint256 = self._get_share_price()
	shares: uint256 = _assets / share_price
	# TODO TEST  https://github.com/fubuloubu/ERC4626/blob/55e22a6757b79abf733bfcaef8d1096311a5314f/contracts/VyperVault.vy#L214-L216

	# TODO TEST how  withdraw fee inflatino affects the shares/asssets that they are *supposed* to lose
		
	# minting adversly affects pool but not withdrawer who should be the one penalized.
	# make them burn extra shares instead of inflating total supply.
	# use _calc not _mint_and_calc. 
	withdraw_fee: uint256 = self._calc_fee(shares, self.fees.withdraw)
	log RevenueGenerated(_receiver, self, withdraw_fee, shares,  FEE_TYPES.WITHDRAW, self) # log potential fees for product analytics

	#  remove _assets/shares from pool
	# NOTE: _transfer in _burn checks callers approval to operate owner's assets
	self._burn(_receiver, shares + withdraw_fee, _assets)
	self._erc20_safe_transfer(ASSET, _receiver, _assets)

	log Withdraw(shares, _owner, _receiver, msg.sender, _assets)
	log TrackSharePrice(share_price, share_price, self._get_share_APR()) # log price/apr for product analytics

	return shares


@internal
@nonreentrant("price_update")
def _update_shares(_assets: uint256, _impair: bool = False) -> (uint256, uint256):
	"""
	@return diff in APR, diff in owner fees
	"""
	init_share_price: uint256 = self._get_share_price() # ensure fresh price before updating

	if not _impair:
		# correct current share price and distributed dividends before updating share valuation
		self._unlock_profits()

		self.total_assets += _assets
		self.locked_profit += _assets
		# Profit is locked and gradually released per block

		return (_assets, 0) # TODO return change in APR
	else:
		# If available, take performance fee from delegate to offset impairment and protect depositors
		fees_to_burn: uint256 = self.accrued_fees
		assets_burned: uint256 = fees_to_burn * init_share_price
		total_to_burn: uint256 = _assets / init_share_price

		# cap fees burned to actual amount being burned
		if fees_to_burn > total_to_burn:
			fees_to_burn = total_to_burn

		self.accrued_fees -= fees_to_burn
		self._burn(self.owner, fees_to_burn, assets_burned)
		# reducing supply during impairment means share price goes UP immediately

		# TODO if changing delegate burn price, use same price for asset_diff
		pool_assets_lost: uint256 = _assets - assets_burned

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
			locked_profit_before_loss: uint256 = self._calc_locked_profit() 

			# reduce APR but keep share price stable if possible
			if locked_profit_before_loss >= pool_assets_lost: 
				self.locked_profit = locked_profit_before_loss - pool_assets_lost
			else:
				self.locked_profit = 0

			# delegate fees not enough to eat losses. Socialize the plebs
			# Auto dump so share price immediately falls (prevent bankrun with negative APYs)
			self.total_assets -= pool_assets_lost

		# correct current share price and distributed dividends after eating losses
		self._unlock_profits()
		
		return (pool_assets_lost, fees_to_burn) # TODO return change in APR
	
	# no default behavior. all logic nested in `if impair:``
	# log price change after updates
	# TODO check that no calling functions also emit 
	log TrackSharePrice(init_share_price, self._get_share_price(), self._get_share_APR())

@internal
@nonreentrant("price_update")
def _unlock_profits() -> uint256:
	locked_profit: uint256 = self._calc_locked_profit()
	vested_profits: uint256 = self.locked_profit - locked_profit
	
	self.locked_profit -= vested_profits
	self.last_report = block.timestamp

	log UnlockProfits(vested_profits, locked_profit, self.vesting_rate)

	return vested_profits

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
		return 1
		# return 10**convert(DECIMALS, uint256) # prevent division by 0 to

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
	pct_profit_locked: uint256 = (block.timestamp - self.last_report) * self.vesting_rate

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
	TODO doesnt work. cant get symbol from _asset

	@dev 		 		if we dont directly copy the `asset`'s decimals then we need to do decimal conversions everytime we calculate share price
	@param _symbol	 	custom symbol input by pool creator
	@return 			e.g. ddpDAI-LLAMA, ddpWETH-KARPATKEY
	"""
	sym: String[3] = ""

	success: bool = False
	_sym: Bytes[18] = b""
	success, _sym = raw_call(
		_asset,
		method_id("symbol()"),
		max_outsize=18,
		is_static_call=True,
		revert_on_failure=False
	)

	if success and len(_sym) != 0:
		sym = convert(slice(_sym, 0, 3), String[3])
	# else:
		# sym = slice(IERC20Detailed(asset).symbol(), 0, 6)

	return concat("ddp", sym, _symbol)


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
		method_id("decimals()"),
		max_outsize=8, is_static_call=True, revert_on_failure=False
	)

	if not success:
		raise "no asset decimals"

	return convert(asset_decimals, uint8)


# 	         IERC 3156 Flash Loan functions
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
	if _token != ASSET:
		return 0
	else:
		return self._get_max_liquid_assets()

@view
@internal
def _get_flash_fee(_token: address, _amount: uint256) -> uint256:
	"""
	@notice slight wrapper _calc_fee to account for liquid assets that can be lent
	"""
	return self._calc_fee(min(_amount, self._get_max_liquid_assets()), self.fees.flash)

@view
@external
def flashFee(_token: address, _amount: uint256) -> uint256:
	assert _token == ASSET
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
	self._erc20_safe_transfer(ASSET, msg.sender, amount)

	fee: uint256 = self._get_flash_fee(_token, amount)
	log RevenueGenerated(msg.sender, ASSET, fee, amount, FEE_TYPES.FLASH, self)

	# ensure they can receive flash loan and are ERC3156 compatible
	assert IERC3156FlashBorrower(receiver).onFlashLoan(msg.sender, _token, amount, fee, data) == keccak256("ERC3156FlashBorrower.onFlashLoan")

	IERC20(ASSET).transferFrom(msg.sender, self, amount + fee)

	self._update_shares(fee)

	return True

# EIP712 permit functionality

@pure
@external
def v() -> String[18]:
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
@external
def n() -> String[18]:
	return CONTRACT_NAME

@view
@internal
def domain_separator() -> bytes32:
	return keccak256(
		concat(
			DOMAIN_TYPE_HASH,
			keccak256(convert(CONTRACT_NAME, Bytes[13])),
			keccak256(convert(API_VERSION, Bytes[7])),
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
	return self._get_max_liquid_assets()





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


interface IRevenueGenerator:
	def owner() -> address: view
	def pending_owner() -> address: view
	def set_owner(_new_owner: address) -> bool: nonpayable
	def accept_owner() -> bool: nonpayable

	def rev_recipient() -> address: view
	def pending_rev_recipient() -> address: view
	def set_rev_recipient(_new_recipient: address) -> bool: nonpayable
	def accept_rev_recipient() -> bool: nonpayable

	# @notice how many tokens can be sent to rev_recipient by caller
	def claimable_rev(_token: address) -> uint256: view
	#  @notice optional. MAY do push payments. if push payments then revert.
	def claim_rev(_token: address, _amount: uint256) -> bool: nonpayable
	#  @notice optional. Requires mutualConsent. Must return IRevenueGenerator.payInvoice.selector if function is supported.
	# def accept_invoice(_from: address, _token: address, _amount: uint256, _note: String[2048]) -> uint256: nonpayable

# Debt DAO interfaces

interface ISecuredLine:
	def borrower() -> address: pure
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
	def depositAndRepay(amount: uint256) -> bool: nonpayable

	# divest
	def withdraw(id: bytes32,  amount: uint256) -> bool: nonpayable

	# leverage
	def borrow(id: bytes32,  amount: uint256) -> bool: nonpayable


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

event UnlockProfits:
	amount: indexed(uint256)
	remaining: indexed(uint256)
	vesting_rate: indexed(uint256)

# Investing Events
event Impair:
	id: indexed(bytes32)
	recovered: indexed(uint256)
	lost: indexed(uint256)
	old_apr: int256
	new_apr: int256
	share_price: uint256
	fees_burned: uint256

event InvestVault:
	vault: indexed(address)
	assets: indexed(uint256)
	shares: indexed(uint256)

event DivestVault:
	vault: indexed(address)
	assets: indexed(uint256)
	shares: uint256
	profit_or_loss: indexed(uint256) # how many assets we realized as losses or gained (NOT YET realized) as profit when divesting
	is_profit: bool

# fees

event UpdateFee:
	fee_bps: indexed(uint16)
	fee_type: indexed(FEE_TYPES)

event NewPendingRevRecipient:
	new_recipient: address 	# New active management fee

event AcceptRevRecipient:
	new_recipient: address 	# New active management fee

event RevenueGenerated:		# standardize revenue reporting for offchain analytics
	payer: indexed(address) # where fees are being paid from
	token: indexed(address) # where fees are being paid from
	revenue: indexed(uint256) # total assets that fees were generated on (user deposit, flashloan, loan principal, etc.)
	amount: uint256			# tokens paid in fees, denominated in 
	fee_type: FEE_TYPES 		# maps to app specific fee enum or eventually some standard fee code system
	receiver: address 		# who is getting the fees paid

event FeesClaimed:
	recipient: indexed(address)
	fees: indexed(uint256)


# Admin updates

event NewPendingOwner:
	pending_owner: indexed(address)

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



# Testing events
event named_uint:
	num: indexed(uint256)
	str: indexed(String[100])

event named_addy:
	addy: indexed(address)
	str: indexed(String[100])
