# @version ^0.3.9

"""
@title 	Debt DAO Lending Pool
@author	Kiba Gateaux
@notice	Tokenized, liquid 4626 pool allowing depositors to collectively lend to Debt DAO Line of Credit contracts
@dev	All investment decisions and pool paramters are controlled by the pool owner aka "Delegate"


TODO - 
6. implement _virtual_apr()
10. Add performance fee to 4626 profits?
5. understand how DEGREDATION_COEFFICIENT works
11. add separate var from total_assets called total_debt and use that instead.
	Prevents lvg from fucking up share price. can incorporate debt into share price if we want
8. should we call _unlock_profits on - deposit, withdraw, invest, divest?
1. Refactor yearn permit() so args are exactly 2612 standard
2. Add permit + permit2 IERC4626P extension and implement functions
4. add custom errors to all reverts
2. add IERC4626RP (referral + permit)
3. Make sure using appropriate instances of total_assets, total_deployed, liquid_assets, vault_assets, etc. in state updates and price algorithms
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
	def impair(line: address, _id: bytes32) -> (uint256, uint256): nonpayable
	def reduce_credit(_line: address, _id: bytes32, amount: uint256) -> (uint256, uint256): nonpayable
	def use_and_repay(_line: address, repay: uint256, withdraw: uint256) -> (uint256, uint256): nonpayable
	
	# external 4626 interactions
	def divest_vault(vault: address, amount: uint256) -> bool: nonpayable
	def invest_vault(vault: address, amount: uint256) -> uint256: nonpayable

	# Pool Admin
	def set_max_assets(new_max: uint256) -> bool: nonpayable
	def set_min_deposit(new_min: uint256) -> bool: nonpayable
	def set_vesting_rate(vesting_rate: uint256): nonpayable

	def stake_assets(_assets: uint256) -> uint256: nonpayable
	def initiate_unstake(_shares: uint256) -> uint256: nonpayable
	def unstake_shares(_index: uint256, _receiver: address): nonpayable

	# fees
	def set_performance_fee(fee: uint16) -> bool: nonpayable
	def set_collector_fee(fee: uint16) -> bool: nonpayable
	def set_withdraw_fee(fee: uint16) -> bool: nonpayable
	def set_referral_fee(fee: uint16) -> bool: nonpayable
	def set_deposit_fee(fee: uint16) -> bool: nonpayable
	def set_flash_fee(fee: uint16) -> bool: nonpayable


### Constants
### TODO only making public for testing purposes. ideally could remain private but still have easy access from tests

# DEV NOTE: constants are public bc of error in boa that prevents reading them for tests 
# https://github.com/vyperlang/titanoboa/issues/47
# TODO fix bug in boa so we can remove

# @notice 100% in bps. Used to divide after multiplying bps fees. Also max performance fee.
FEE_COEFFICIENT: public(constant(uint256)) = 10000
# @notice 5% in bps. snitch gets 1/20 of owners fees when liquidated to repay impairment.
# ONLY IF owner fees exist when snitched on.
SNITCH_FEE: public(constant(uint16)) = 500
# @notice 5% in bps. Max fee that can be charged for non-performance fee
MAX_PITTANCE_FEE: public(constant(uint16)) = 200
# @notice How long delegate has to wait to claim stake after initiating withdrawal. 7 days in seconds
UNSTAKE_TIMELOCK: public(constant(uint256)) = 60*60*24 * 7 # 7 days

# rate per block of profit degradation. VESTING_RATE_COEFFICIENT is 100% per block
VESTING_RATE_COEFFICIENT: public(constant(uint256)) = 10 ** 18
# One qeek = 4 eeks = 4 * 2048 epochs = 4 eeks * 32 blocks * 12 seconds * 2048 epochs =? (COEFFICIENT / (4 * 32 * 2048) / 10**6)
FOUR_EEKS_VESTING_RATE: public(constant(uint256)) = (VESTING_RATE_COEFFICIENT / (4 * 32 * 2048 * 12)) / 10**6
# @notice EIP712 contract name
CONTRACT_NAME: public(constant(String[13])) = "Debt DAO Pool"
# @notice EIP712 contract version
API_VERSION: public(constant(String[7])) = "0.0.001"
# @notice EIP712 type hash
DOMAIN_TYPE_HASH: constant(bytes32) = keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
# @notice EIP712 permit type hash
PERMIT_TYPE_HASH: constant(bytes32) = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
# Debt DAO SecuredLine statuses from LineLib.STATUS (vyper and solidity convert enums differerntly)
STATUS_UNINITIALIZED: constant(uint8) = 0
STATUS_ACTIVE: constant(uint8) = 1
STATUS_LIQUIDATABLE: constant(uint8) = 2
STATUS_REPAID: constant(uint8) = 3
STATUS_INSOLVENT: constant(uint8) = 4


# IERC20 vars
NAME: immutable(String[50])
SYMBOL: immutable(String[18])
DECIMALS: immutable(uint8)
# 10**8. Decimals to add to share price to prevent rounding errors
PRICE_DECIMALS: public(constant(uint256)) = 10**8
# total amount of shares in pool
total_supply: public(uint256)
# balance of pool vault shares
balances: HashMap[address, uint256]
# owner -> spender -> amount approved
allowances: HashMap[address, HashMap[address, uint256]]

# IERC4626 vars
# underlying token for pool/vault
ASSET: immutable(address)
# total notional amount of underlying token owned by pool (may not be currently held in pool)
total_assets: public(uint256)

# share price logic stolen from yearn vyper vaults
# vars - https://github.com/yearn/yearn-vaults/blob/74364b2c33bd0ee009ece975c157f065b592eeaf/contracts/Vault.vy#L239-L242
# block.timestamp of last report
last_report: public(uint256)
# how many base tokens earned as profit are locked and cant be withdrawn
locked_profits: public(uint256)
# The rate of degradation in percent per second scaled to 1e18. 
# lower the coefficient the slower the profit drip
# VESTING_RATE_COEFFICIENT is 100% per block
vesting_rate: public(uint256)

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
# shares deposited by delegaet as collateral to manage pool
delegate_stake: public(uint256)
# delegate stake withdrawals with timelock. block timestamp -> amount
unstake_queue: public(HashMap[uint256, uint256])

# minimum amount of assets that can be deposited at once. whales only, fuck plebs.
min_deposit: public(uint256)
# maximum amount of asset deposits to allow into pool
max_assets: public(uint256)
# total amount of asset held externally in lines or vaults
# @dev 0 <= total_deployed <= total_assets + debt_principal
total_deployed: public(uint256)
# amount of assets held by external 4626 vaults. used to calc profit/loss on non-line investments
vault_investments: public(HashMap[address, uint256])
# how much loss we realized on position at time of impairment. Can still theoretically repay with future revenue
impairments: public(HashMap[address, uint256])
# total notional amount of ASSET borrowed from lines. Does not include interest owed.
debt_principal: public(uint256)


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
	self._assert_pittance_fee(_fees.deposit, FEE_TYPES.DEPOSIT)
	self._assert_pittance_fee(_fees.withdraw, FEE_TYPES.WITHDRAW)
	self._assert_pittance_fee(_fees.flash, FEE_TYPES.FLASH)
	self._assert_pittance_fee(_fees.collector, FEE_TYPES.COLLECTOR)
	self._assert_pittance_fee(_fees.referral, FEE_TYPES.REFERRAL)

	# Setup Pool variables
	self.fees = _fees
	self.owner = _delegate
	self.rev_recipient = _delegate
	self.max_assets = max_value(uint256)
	self.min_deposit = 1

	# IERC20 vars
	NAME = self._get_pool_name(_name)
	SYMBOL = _symbol
	# MUST use same decimals as `asset` token. revert if call fails
	# We do not account for different base/vault token decimals in our math
	DECIMALS = IERC20Detailed(_asset).decimals()
	assert DECIMALS != 0, "bad decimals" # 0 could be non-standard `False` or revert

	# IERC4626
	ASSET = _asset

	# NOTE: Yearn - set profit to be distributed every 6 hours
	# self.vesting_rate = convert(VESTING_RATE_COEFFICIENT * 46 / 10 ** 6 , uint256)

	# TODO: Debt DAO - set profit to bedistributed to every `4 eek` (ethereum week)
	# 4 * 2048 epochs = 4 * 32 * 2048 blocks = COEFFICIENT / (4 * 32 * 2048) / 10 ** 6 ???
	self.vesting_rate = FOUR_EEKS_VESTING_RATE
	self.last_report = block.timestamp

	# IERC2612
	CACHED_CHAIN_ID = chain.id # cache before compute
	CACHED_COMAIN_SEPARATOR = self.domain_separator()


### Investing functions

@internal
def _assert_owner_has_available_funds(amount: uint256):
	assert msg.sender == self.owner, "not owner"
	assert self.total_assets - self.total_deployed >= amount

@external
@nonreentrant("lock")
def add_credit(_line: address, _drate: uint128, _frate: uint128, _amount: uint256) -> bytes32:
	self._assert_owner_has_available_funds(_amount)
	 # TODO rename to prevent delegate confusion btw this add_credit and accept_offer which also call SecuredLine.addCredit()
	assert ISecuredLine(_line).borrower() != self
	
	self.total_deployed += _amount
	
	# NOTE: no need to log, Line emits events already
	IERC20(ASSET).approve(_line, _amount)
	return ISecuredLine(_line).addCredit(_drate, _frate, _amount, ASSET, self)

@external
@nonreentrant("lock")
def increase_credit(_line: address, _id: bytes32, _amount: uint256) -> bool:
	self._assert_owner_has_available_funds(_amount)

	self.total_deployed += _amount

	# NOTE: no need to log, Line emits events already
	IERC20(ASSET).approve(_line, _amount)
	ISecuredLine(_line).increaseCredit(_id, _amount)
	return True

@external
def set_rates(_line: address, _id: bytes32, drate: uint128, frate: uint128) -> bool:
	assert msg.sender == self.owner, "not owner"
	# NOTE: no need to log, Line emits events already
	ISecuredLine(_line).setRates(_id, drate, frate)
	return True

@external
@nonreentrant("lock")
def collect_interest(_line: address, _id: bytes32) -> uint256:
	"""
	@notice
		Anyone can claim interest from active lines and start vesting profits into pool shares
	@return
		Amount of assets earned in Debt DAO Line of Credit contract
	"""
	return self._reduce_credit(_line, _id, 0)[1]


@external
@nonreentrant("lock")
def unlock_profits() -> uint256:
	"""
	@notice 
		Anyone can released vested profits into pool shares at any time
	@ return
		Amouunt of assets unlocked as profit
	"""
	return self._unlock_profits()


@external
@nonreentrant("lock")
def abort(_line: address, _id: bytes32) -> (uint256, uint256):
	"""
	@notice emergency cord to remove all avialable funds from a _line (deposit + interestRepaid)
	"""
	assert msg.sender == self.owner, "not owner"
	return self._reduce_credit(_line, _id, max_value(uint256))

@external
@nonreentrant("lock")
def reduce_credit(_line: address, _id: bytes32, _withdraw_amount: uint256) -> (uint256, uint256):
	assert msg.sender == self.owner, "not owner"
	return self._reduce_credit(_line, _id, _withdraw_amount)

@external
@nonreentrant("lock")
def use_and_repay(_line: address, _repay_amount: uint256, _withdraw_amount: uint256) -> (uint256, uint256):
	assert msg.sender == self.owner, "not owner"

	# Assume we are next lender in queue. 
	# save id for later incase we repay full amount and stepQ
	id: bytes32 = ISecuredLine(_line).ids(0)

	# NOTE: no need to log, Line emits events already
	assert ISecuredLine(_line).useAndRepay(_repay_amount)

	return self._reduce_credit(_line, id, _withdraw_amount)

@external
@nonreentrant("lock")
def impair(_line: address, _id: bytes32) -> (uint256, uint256):
	"""
	@notice     - markdown the value of an insolvent loan reducing vault share price over time
				- Callable by anyone to prevent delegate from preventing numba go down
	@param _line - _line of credit contract to call
	@param _id   - credit position on _line controlled by this pool 
	"""
	# check we haven't already realized loss on this position.
	# prevent replay attacks to drain owners accrued fees or fuck up pool math
	assert self.impairments[_line] == 0 # TODO TEST line cant be un-insolved  so no replay chance. Do we need reundant check in pool too?
	assert ISecuredLine(_line).status() == STATUS_INSOLVENT

	position: Position = ISecuredLine(_line).credits(_id)
	# validate line is ours and has a loss to realize
	# if no borrower debt, Pool Delegate can just call reduce_credit(MAX_UINT) and withdraw like normal
	assert position.lender == self and position.principal != 0

	pool_net_loss: uint256 = 0
	fees_burned: uint256 = 0
	# initial principal we can recoup (separate from interest payments we can still claim)
	recovered: uint256 = position.deposit - position.principal
	# total amount we can pull from line
	withdrawable: uint256 = recovered + position.interestRepaid

	if position.interestRepaid > position.principal:
		# increase share price by net profit
		self._update_shares(position.interestRepaid - position.principal)
		# TODO take performance fees? technically no loss on position, pure profit still
		# we still record lost principal later
	else:
		# report losses
		# reduce loss by earned interest before marking down share price
		(pool_net_loss, fees_burned) = self._update_shares(position.principal - position.interestRepaid, True)
		if fees_burned != 0 and msg.sender != self.owner:
			# snitch was successful. payout mev
			# TODO move to uopdate_share where we burn fees?
			snitch_fee: uint256 = self._calc_fee(fees_burned, SNITCH_FEE)
			log RevenueGenerated(msg.sender, self, snitch_fee, fees_burned, convert(FEE_TYPES.SNITCH, uint256), ASSET)
			self._erc20_safe_transfer(ASSET, msg.sender, self._convert_to_assets(snitch_fee))

	# update pool accounting with recovery stats

	# return deposit to liquid pool
	self.total_deployed -= recovered
	# track how much we realized as a loss incase borrower makes repayments later
	# reflect notional tokens to recover from line still (regardless of losses covered by delegate
	self.impairments[_line] = position.principal
	# claim all funds left in line
	# NOTE: no need to log, Line emits events already
	ISecuredLine(_line).withdraw(_id, withdrawable)

	log Impair(_line, _id, recovered, position.interestRepaid, fees_burned, pool_net_loss, position.principal)
	
	return (pool_net_loss, fees_burned)

### External 4626 vault investing

@external
@nonreentrant("lock")
def invest_vault(_vault: address, _amount: uint256) -> uint256:
	self._assert_owner_has_available_funds(_amount)

	self.total_deployed += _amount
	self.vault_investments[_vault] += _amount

	# NOTE: Owner should check previewDeposit(`_amount`) expected vs `_amount` for slippage ?
	IERC20(ASSET).approve(_vault, _amount)
	shares: uint256 = IERC4626(_vault).deposit(_amount, self)

	log InvestVault(_vault, _amount, shares) ## TODO shares
	return shares


@external
@nonreentrant("lock")
def divest_vault(_vault: address, _amount: uint256) -> bool:
	"""
	TODO How to account for vault withdraw fees automatically making is_loss true whenever this is called. Even withcout snitch fee being profitable u could DOS Delegate by constantly reverting
	would be nice to return how many shares were burned
	"""
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
		# Can't be used to steal what this pool is protecting
		value = IERC20(ASSET).balanceOf(self) - (self.total_assets - self.total_deployed)
	elif _token == self:
		# recover shares sent directly to pool, minus fees held for owner.
		value = self.balances[self] - self.accrued_fees - self.delegate_stake
	elif _amount == max_value(uint256):
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
	assert msg.sender == new_owner, "not pending owner"
	self.owner = new_owner
	log AcceptOwner(new_owner)
	return True

@external
def set_min_deposit(new_min: uint256)  -> bool:
	assert msg.sender == self.owner, "not owner"
	assert new_min != 0
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
def _assert_max_fee(_fee: uint16, _fee_type: FEE_TYPES):
  assert msg.sender == self.owner, "not owner"
  assert convert(_fee, uint256) <= FEE_COEFFICIENT, "bad performance _fee" # max 100% performance _fee
  log FeeSet(_fee, convert(_fee_type, uint256))

@external
@nonreentrant("lock")
def set_performance_fee(_fee: uint16) -> bool:
  self._assert_max_fee(_fee, FEE_TYPES.PERFORMANCE)
  self.fees.performance = _fee
  return True

@internal
def _assert_pittance_fee(_fee: uint16, fee_type: FEE_TYPES):
	assert msg.sender == self.owner, "not owner"
	assert _fee <= MAX_PITTANCE_FEE, "bad pittance fee"
	log FeeSet(_fee, convert(fee_type, uint256))

@external
@nonreentrant("lock")
def set_flash_fee(_fee: uint16) -> bool:
	self._assert_pittance_fee(_fee, FEE_TYPES.FLASH)
	self.fees.flash = _fee
	return True

@external
@nonreentrant("lock")
def set_collector_fee(_fee: uint16) -> bool:
	self._assert_pittance_fee(_fee, FEE_TYPES.COLLECTOR)
	self.fees.collector = _fee
	return True

@external
@nonreentrant("lock")
def set_deposit_fee(_fee: uint16) -> bool:
	self._assert_pittance_fee(_fee, FEE_TYPES.DEPOSIT)
	self.fees.deposit = _fee
	return True

@external
@nonreentrant("lock")
def set_withdraw_fee(_fee: uint16) -> bool:
	self._assert_pittance_fee(_fee, FEE_TYPES.WITHDRAW)
	self.fees.withdraw = _fee
	return True

@external
@nonreentrant("lock")
def set_referral_fee(_fee: uint16) -> bool:
	self._assert_pittance_fee(_fee, FEE_TYPES.REFERRAL)
	self.fees.referral = _fee
	return True

@external
def set_rev_recipient(_new_recipient: address) -> bool:
  assert msg.sender == self.rev_recipient, "not rev_recipient"
  self.pending_rev_recipient = _new_recipient
  log NewPendingRevRecipient(_new_recipient)
  return True

@external
def accept_rev_recipient() -> bool:
  assert msg.sender == self.pending_rev_recipient, "not pending rev_recipient"
  self.rev_recipient = msg.sender
  log AcceptRevRecipient(msg.sender)
  return True

@external
@view
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
	assert _token == self, "non-revenue token"
	assert msg.sender == self.rev_recipient, "not rev_recipient"

	claimed: uint256 = _amount
	if _amount == max_value(uint256):
		claimed = self.accrued_fees # set to max available
	
	# transfer fee shares locked in pool to fee recipient
	self.accrued_fees -= claimed # reverts on underflow
	# manually approve bc we can never be msg.sender in internal _transfer
	self._approve(self, msg.sender, claimed)
	self._transfer(self, msg.sender, claimed)

	log RevenueClaimed(self.rev_recipient, claimed)
	# log price for product analytics
	price: uint256 = self._virtual_price()
	# log TrackSharePrice(price, price, self._virtual_apr())

	return True

@external
@nonreentrant("lock")
def set_vesting_rate(_vesting_rate: uint256):
	"""
	@notice
		Changes the locked profit _vesting_rate.
	@param _vesting_rate The rate of _vesting_rate in percent per second scaled to 1e18.
	"""
	assert msg.sender == self.owner, "not owner"
	# Since "_vesting_rate" is of type uint256 it can never be less than zero
	assert _vesting_rate <= VESTING_RATE_COEFFICIENT
	self.vesting_rate = _vesting_rate
	log UpdateProfitVestingRate(_vesting_rate) 


@external
@nonreentrant("lock")
def stake_assets(_assets: uint256) -> uint256: 
	"""
	@notice
		Stake assets to pool as first loss protection for depositors.
		Convert to shares to earn profits from investments
	@dev 
		Anyone can stake assets
	@param _assets The amount of assets to stake.
	@return shares_staked - amount of shares minted for staking
	"""
	assert _assets != 0, "zero assets"
	shares_staked: uint256 = self._deposit(_assets, self._convert_to_shares(_assets), self)
	self.delegate_stake += shares_staked
	log StakeAssets(msg.sender, _assets, shares_staked)
	return shares_staked


@external
@nonreentrant("lock")
def initiate_unstake(_shares: uint256) -> uint256:
	"""
	@notice
		Starts qithdrawal process for delegate to Remove shares from first loss pool
		Each unstake process is identified by the block that its timelock ends at
	@dev we use shares instead of assets in case share price changes between initiation and unstaking
	@param _shares The amount of pool shares to return to delegate.
	@return
		Block that owner can claim unstaked s hares
	"""
	assert _shares != 0 # dev: zero value
	assert msg.sender == self.owner  # dev: not pool owner
	assert self.delegate_stake >= _shares # dev: not enough shares to unstake
	
	unlock_index: uint256 = block.timestamp + UNSTAKE_TIMELOCK
	self.unstake_queue[unlock_index] = _shares

	log InitiateUnstake(unlock_index, _shares)
	return unlock_index

@external
@nonreentrant("lock")
def unstake_shares(_index: uint256, _receiver: address):
	"""
	@notice
		Removes shares from first loss pool of delegate stake 
	@param _index The block timestamp that unstake can be withdrawn at
	@param _receiver The address to send unstaked shares to
	"""
	assert _index < block.timestamp # dev: queue not ready
	assert msg.sender == self.owner  # dev: not pool owner

	shares_unstaked: uint256 = self.unstake_queue[_index]
	assert shares_unstaked != 0 # dev: index not in unstake queue
	# ensure stake hasnt been slashed since initiating unstake
	assert self.delegate_stake >= shares_unstaked # dev: not enough shares to unstake
	
	self.unstake_queue[_index] = 0
	self.delegate_stake -= shares_unstaked

	self._transfer(self, _receiver, shares_unstaked)
	
	log UnstakeShares(_index, shares_unstaked)



### ERC4626 Functions
@external
@nonreentrant("lock")
def deposit(_assets: uint256, _receiver: address) -> uint256:
	"""
		@dev
			update share price before taking action to prevent stale virtual price being exploited
		@return - shares caller received for depositing `_assets` tokens
	"""
	self._unlock_profits()
	return self._deposit(_assets, self._convert_to_shares(_assets), _receiver)

@external
@nonreentrant("lock")
def depositWithReferral(_assets: uint256, _receiver: address, _referrer: address) -> uint256:
	"""
		@dev
			update share price before taking action to prevent stale virtual price being exploited
		@return - shares caller received for depositing `_assets` tokens
	"""
	self._unlock_profits()
	return self._deposit(_assets, self._convert_to_shares(_assets), _receiver, _referrer)

@external
@nonreentrant("lock")
def mint(_shares: uint256, _receiver: address) -> uint256:
	"""
		@dev
			update share price before taking action to prevent stale virtual price being exploited
		@return assets - amount of assets caller deposited to receive exactly `_shares` shares back
	"""
	self._unlock_profits()
	# save original share price bc price potentially changes after minflation fees
	# so `assets` return value is what user actually paid
	assets: uint256 = self._convert_to_assets(_shares)
	self._deposit(assets, _shares, _receiver)
	return assets

@external
@nonreentrant("lock")
def mintWithReferral(_shares: uint256, _receiver: address, _referrer: address) -> uint256:
	"""
		@dev
			update share price before taking action to prevent stale virtual price being exploited
		@return assets - amount of assets caller deposited to receive exactly `_shares` shares back
	"""
	self._unlock_profits()
	# save original share price bc price potentially changes after minflation fees
	# so `assets` return value is what user actually paid
	assets: uint256 = self._convert_to_assets(_shares)
	self._deposit(assets, _shares, _receiver, _referrer)
	return assets

@external
@nonreentrant("lock")
def withdraw(
	_assets: uint256,
	_receiver: address,
	_owner: address
) -> uint256:
	"""
		@dev
			update share price before taking action to prevent stale virtual price being exploited
		@return - shares
	"""
	self._unlock_profits()
	return self._withdraw(_assets, _owner, _receiver)

@external
@nonreentrant("lock")
def redeem(_shares: uint256, _receiver: address, _owner: address) -> uint256:
	"""
		@dev
			update share price before taking action to prevent stale virtual price being exploited
		@return - assets
	"""
	self._unlock_profits()
	return self._redeem(_shares, _owner, _receiver)

### ERC20 Functions

@external
@nonreentrant("lock")
def transfer(_to: address, _amount: uint256) -> bool:
	if _to == empty(address):
		return self._burn(msg.sender, _amount)
	else:
		return self._transfer(msg.sender, _to, _amount)

@external
@nonreentrant("lock")
def transferFrom(_sender: address, _receiver: address, _amount: uint256) -> bool:
	self._assert_caller_has_approval(_sender, _amount)
	return self._transfer(_sender, _receiver, _amount)


@external
def approve(_spender: address, _amount: uint256) -> bool:
	return self._approve(msg.sender, _spender, _amount)

@external
def increaseAllowance(_spender: address, _amount: uint256) -> bool:
	return self._approve(msg.sender, _spender, self.allowances[msg.sender][_spender] + _amount)


### Internal Functions 

# transfer + approve vault shares
@internal
def _approve(_owner: address, _spender: address, _amount: uint256) -> bool:
	self.allowances[_owner][_spender] = _amount
	# NOTE: Allows log filters to have a full accounting of allowance changes
	log Approval(_owner, _spender, _amount)
	return True

@internal
def _transfer(_sender: address, _receiver: address, _amount: uint256) -> bool:
	if _sender != empty(address):
		# if not minting, then ensure _sender has balance
		self.balances[_sender] -= _amount
	
	if _receiver != empty(address):
		# if not burning, add to _receiver
		# when burned, shares dissapear to reduce supply but we still have logs to track existence
		self.balances[_receiver] += _amount
	
	log Transfer(_sender, _receiver, _amount)
	return True

@internal
def _assert_caller_has_approval(_owner: address, _amount: uint256) -> bool:
	if msg.sender != _owner:
		allowance: uint256 = self.allowances[_owner][msg.sender]
		# MAX = unlimited approval (saves an SSTORE)
		if (allowance < max_value(uint256)):
			# update caller allowance based on usage
			# reverts on underflow to ensure proper allowance
			self._approve(_owner, msg.sender, allowance - _amount)

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
		# raw_revert(method_id("TransferFailed"))


# TODO TEST implement _erc20_safe_transfer_from and replace

# 4626 + Pool internal functions

# inflate supply to take fees. reduce share price. tax efficient.

@internal
def _mint(_to: address, _shares: uint256) -> bool:
	"""
	@notice
		Inc internal supply with new assets deposited and shares minted
	"""
	self.total_supply += _shares
	self._transfer(empty(address), _to, _shares)
	return True

@internal
def _burn(owner: address, _shares: uint256) -> bool:
	"""
	"""
	self.total_supply -= _shares
	self._transfer(owner, empty(address), _shares)
	return True


@internal
@pure
def _calc_fee(shares: uint256, fee: uint16) -> uint256:
	"""
	@dev	does NOT emit `log RevenueGenerated` like _mint_and_calc. Must manuualy log if using this function whil changing state
	"""
	if fee == 0:
		return 0
	else:
		return (shares * convert(fee, uint256)) / FEE_COEFFICIENT

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
			# store delegate fees separately from delegate balance so we can slash if neccessary
			self._mint(self, fees)
			self.accrued_fees += fees
		else:
			# mint other ecosystem participants fees to them directly
			self._mint(to, fees)

	# log fees even if 0 so we can simulate potential fee structures post-deployment
	log RevenueGenerated(payer, self, fees, shares, convert(fee_type, uint256), to)
	
	return fees

@internal 
def _divest_vault(_vault: address, _amount: uint256) -> (bool, uint256):
	"""
	@notice
		Anyone can divest entire vault balance as soon as a potential loss appears due to snitch incentive.
		This automatically protects pool depositors from staying in bad investments in liquid vaults unlike Lines where we can't clawback as easily.
		On the otherhand Lines give Delegates more control over the investment process + additional incentives via performance fee.

		Good dynamic where Lines have higher yield to fill accrued_fees but lower liquidity / capacity (high risk, high reward) so Delegate overflows to 4626 investments.
		4626 is more liquid, goes straight to users w/o fees, and has better snitch protections (low risk, low reward).
	@return
		bool - if we realized profit or not
		uint256 - profit withdrawn (in assets)
	@dev
		We always reduce oustanding principal deposited in vault to 0 and then all withdrawals add to profit.
	"""
	is_loss: bool = True # optimistic pessimism
	net: uint256 = 0
	curr_shares: uint256 = IERC20(_vault).balanceOf(self)
	principal: uint256 = self.vault_investments[_vault] # MAY be a 0 but thats OK 👍

	if principal == 0 and curr_shares == 0: # nothing to withdraw
		return (False, net) # technically no profit. 0 is cheaper to check too.

	# if using shorthands, set amount to withdraw
	amount: uint256 = _amount
	if _amount == 0:
		amount = principal # only withdraw initial principal
	elif _amount == max_value(uint256):
		amount = IERC4626(_vault).previewWithdraw(_amount) # get all assets deposited in vvault

	burned_shares: uint256 = IERC4626(_vault).withdraw(amount, self, self)
	# can def pull out loss reporting to its own function. mandate that withdraw(amount) is a loss
	# need to ensure that owner is ownly claiming profitable positions still tho if we remove that logic path

	# assert burned_shares == expected_burn # ensure we are exiting at price we expect
	# TODO calculate asset/share price slippage even if # shares are expected 
	# make sure we arent creating the loss ourselves by withdrawing too much at once
	# EIP4626: "Note that any unfavorable discrepancy between convertToAssets and previewRedeem SHOULD be considered slippage in share price or some other type of condition, meaning the depositor will lose assets by redeeming."


	# calculate if we are realizing losses on vault investment
	# MUST ONLY be true when burning last share with outstanding principal left
	is_loss = curr_shares == burned_shares and principal > amount

	log named_uint("burned_shares", burned_shares)
	log named_uint("curr_shares", curr_shares)
	log named_uint("initial principal", principal)
	log named_uint("is_loss", convert(is_loss, uint256))

	if is_loss:
		net = principal - amount
		self.vault_investments[_vault] = 0 # erase debt so no replay attacks
		self._update_shares(net, True)
	elif amount > principal:
		# withdrawing profit (+ maybe principal if != 0)
		# TODO TEST that this math works fine if principal == 0 and its pure profit from the start or if its profit + principal
		net = amount - principal
		self.total_deployed -= principal
		self.vault_investments[_vault] = 0

		self._update_shares(net) 			# add to locked_profit
		self._take_performance_fee(net)		# payout delegate fees on profit
	else:
		# only recouping initial deposit, principal > amount
		self.total_deployed -= amount
		self.vault_investments[_vault] -= amount

	log DivestVault(_vault, amount, burned_shares, net, is_loss)

	return (is_loss, net)


@internal 
def _reduce_credit(_line: address, _id: bytes32, _amount: uint256) -> (uint256, uint256):
	"""
	@notice		withdraw deposit and/or interest from an external position
	@return 	(initial principal withdrawn, interest earned)
	"""
	withdrawable: uint256 = _amount
	interest: uint256 = 0
	deposit: uint256 = 0
	# query line for how much we can immediately withdraw
	(deposit, interest) = ISecuredLine(_line).available(_id)

	if _amount == 0:
		# 0 is shorthand for take maximum _amount of interest
		withdrawable = interest
	elif _amount == max_value(uint256):
		# MAX is shorthand for take all liquid assets
		withdrawable = deposit + interest

	assert withdrawable > 0 # TODO custom error

	# set how much deposit vs interest we are collecting
	# NOTE: MUST come after `_amount` shorthand assignments
	if withdrawable < interest:
		# if we want less than claimable interest, reduce incoming interest
		interest = withdrawable
		deposit = 0
	else:
		# we are withdrawing initial deposit in addition to interest
		deposit = withdrawable - interest
	
	if deposit != 0:
		# return principal to liquid pool
		self.total_deployed -= deposit
		# if we already realized a loss on this position then account for now-unlost principal
		if self.impairments[_line] != 0:
			self.impairments[_line] -= deposit


	if interest != 0:
		self._update_shares(interest) # add to locked profits
		# TODO TEST does taking fees before/after updating shares affect RDT ???
		fees: uint256 = self._take_performance_fee(interest)

	# NOTE: no need to log, Line emits events already
	ISecuredLine(_line).withdraw(_id, withdrawable)

	return (deposit, interest)

@internal
def _take_performance_fee(interest_earned: uint256) -> uint256:
	"""
	@notice takes total profits earned and takes fees for delegate and compounder
	@dev fees are stored as shares but input/ouput assets
	@param interest_earned - total amount of assets claimed as interest payments from Debt DAO Line of Credit contracts
	@return total amount of shares taken as fees
	"""
	performance_fee: uint256 = self._calc_and_mint_fee(self, self.owner, self._convert_to_shares(interest_earned), self.fees.performance, FEE_TYPES.PERFORMANCE)

	# NOTE: only _calc not _mint_and_calc so caller gets collector fees in raw asset for easier MEV
	# calc fee on assets not shares so mintflation doesnt affect collector's payout
	collector_assets: uint256 = self._calc_fee(interest_earned, self.fees.collector)
	if (collector_assets != 0 and msg.sender != self.owner): # lazy eval saves SLOAD
		self.total_assets -= collector_assets
		self._erc20_safe_transfer(ASSET, msg.sender, collector_assets)
		log RevenueGenerated(self, ASSET, collector_assets, interest_earned, convert(FEE_TYPES.COLLECTOR, uint256), msg.sender)
		return performance_fee + self._convert_to_shares(collector_assets)
	
	return performance_fee


@internal
def _deposit(
	_assets: uint256,
	_shares: uint256,
	_receiver: address,
	_referrer: address = empty(address)
) -> uint256:
	"""
	@notice 	- adds shares to a user after depositing into vault
	@dev 		- priviliged internal func
	@return 	- amount of shares received for _assets
	"""
	assert _shares > 0 # cant deposit assets without receiving shares back. Also prevents share price attacks
	assert _assets >= self.min_deposit
	assert self.total_assets + _assets <= self.max_assets # dev: Pool max reached
	assert _receiver != empty(address)

	# call even if fees = 0 to log revenue for prod analytics
	self._calc_and_mint_fee(self, self.owner, _shares, self.fees.deposit, FEE_TYPES.DEPOSIT)

	# dont mint referral fees if depositor isnt being referred by 3rd party
	shares_referred: uint256 = 0
	if _referrer != empty(address):
		shares_referred = _shares

	# call even if fees = 0 to log revenue for prod analytics
	self._calc_and_mint_fee(self, _referrer, shares_referred, self.fees.referral, FEE_TYPES.REFERRAL)

	# TODO TEST how deposit/refer fee inflation affects the _shares/asssets that they are *supposed* to lose

	# use original price, opposite of _withdraw, requires them to deposit more _assets than current price post fee inflation
	self.total_assets += _assets
	self._mint(_receiver, _shares)

	assert IERC20(ASSET).transferFrom(msg.sender, self, _assets) # dev: asset.transferFrom() failed on deposit

	log Deposit(_shares, _receiver, msg.sender, _assets)
	# for testing - log price change after deposit and fee inflation
	# log TrackSharePrice((_assets * PRICE_DECIMALS) / _shares, self._virtual_price(), self._virtual_apr())

	return _shares

@internal
def _withdraw(
	_assets: uint256,
	_owner: address,
	_receiver: address
) -> uint256:
	"""
	@dev - priviliged internal function. Run price updates before calculating _assets/_shares params
	"""
	
	assert _receiver != empty(address)
	assert _assets <= self._max_liquid_assets() 	# dev: insufficient liquidity
	assert self.total_assets - _assets >= self.min_deposit # dev: Pool min reached

	# mintflation fees adversly affects pool but not withdrawer who should be the one penalized.
	# make them burn extra _shares instead of inflating total supply.
	# use _calc not _mint_and_calc + manually log revenue
	shares: uint256 = self._convert_to_shares(_assets)
	withdraw_fee: uint256 = self._calc_fee(shares, self.fees.withdraw)
	# log potential fees for product analytics
	log RevenueGenerated(_owner, self, withdraw_fee, shares, convert(FEE_TYPES.WITHDRAW, uint256), self)

	#  TODO have _asset/_shares == 0 if withdraw/redeem and then dynamically calc withdraw fee in assets or shares
	burned_shares: uint256 = shares + withdraw_fee
	self._burn_and_withdraw(burned_shares, _assets, _owner, _receiver)

	return burned_shares

@internal
def _redeem(
	_shares: uint256,
	_owner: address,
	_receiver: address
) -> uint256:
	"""
	@dev - priviliged internal function. Should run price updates before calculating _assets/_shares params

	"""

	withdraw_fee: uint256 = self._calc_fee(_shares, self.fees.withdraw)
	# log potential fees for product analytics
	log RevenueGenerated(_owner, self, withdraw_fee, _shares, convert(FEE_TYPES.WITHDRAW, uint256), self)

	assets_w_fees: uint256 = self._convert_to_assets(_shares) - self._convert_to_assets(withdraw_fee)	
	self._burn_and_withdraw(_shares, assets_w_fees, _owner, _receiver)

	return assets_w_fees


@internal
def _burn_and_withdraw(_shares: uint256, _assets: uint256, _owner: address, _receiver: address):
	assert _receiver != empty(address)
	assert _shares != 0 and _assets != 0
	# SLOADs last
	assert _shares <= self.total_supply and _assets <= self._max_liquid_assets()

	self._assert_caller_has_approval(_owner, _shares)
	# remove _assets from pool
	self.total_assets -= _assets		
	# Burn shares instead of giving to owner. Withdrawals = owner bad
	self._burn(_owner, _shares)
	self._erc20_safe_transfer(ASSET, _receiver, _assets)

	log Withdraw(_shares, _owner, _receiver, msg.sender, _assets)
	# for testing - log price change after deposit and fee inflation
	# log TrackSharePrice((_assets * PRICE_DECIMALS) / _shares, self._virtual_price(), self._virtual_apr()) # log price/apr for product analytics

@internal
def _update_shares(_assets: uint256, _impair: bool = False) -> (uint256, uint256):
	"""
	@return diff in pool assets (earned or lost), owner fees burned
	"""
	# correct current share price and distributed dividends after eating losses
	self._unlock_profits()
	if not _impair:
		# correct current share price and distributed dividends before updating share valuation

		self.total_assets += _assets
		self.locked_profits += _assets
		# Profit is locked and gradually released per block

		return (_assets, 0) # return early if only declaring profits
	
	# if impair:

	# If available, take performance fee from delegate to offset impairment and protect depositors
	stake_to_burn: uint256 = self.delegate_stake + self.accrued_fees
	total_to_burn: uint256 = self._convert_to_shares(_assets)

	# cap fees burned to actual amount being burned
	if stake_to_burn > total_to_burn:
		stake_to_burn = total_to_burn
	# NOTE: set after updating stake_to_burn
	burned_assets: uint256 = self._convert_to_assets(stake_to_burn)

	# Realize notional pool loss. Reduce share price.
	# NOTE: must reduce AFTER converting amounts to burn from owner/pool
	self.total_assets -= _assets

	# burn owner fees to cover losses
	if stake_to_burn > self.accrued_fees:
		self.accrued_fees = 0
		self.delegate_stake -= stake_to_burn - self.accrued_fees
	else:
		self.accrued_fees -= stake_to_burn

	self._burn(self, stake_to_burn)
	pool_assets_lost: uint256 = _assets - burned_assets

	log named_uint("fees_shares_burn", stake_to_burn)
	log named_uint("fee_assets_burned", burned_assets)
	log named_uint("total_to_burn", total_to_burn)
	log named_uint("pool_assets_lost", pool_assets_lost)

	# TODO TEST feels like theres a bug here. Whats the diff if we do or dont reduce locked_profit?
	# Is it an accounting error if we remove assets from total but not profit?
	# Share price will be the same (assets/supply) regardless of change in locked profit (but APR is diff)
	if pool_assets_lost != 0:
		# delegate fees not enough to eat losses. Socialize across pool
		if self.locked_profits >= pool_assets_lost:
			# reduce APR but keep share price stable if possible
			self.locked_profits -= pool_assets_lost
		else:
			# profit
			self.locked_profits = 0

	return (pool_assets_lost, stake_to_burn)
	
	# log price change after updates
	# TODO check that no calling functions also emit 
	# log TrackSharePrice(init_share_price, self._virtual_price(), self._virtual_apr())

@internal
def _unlock_profits() -> uint256:
	locked_profit: uint256 = self._calc_locked_profit()
	vested_profits: uint256 = self.locked_profits - locked_profit
	
	self.locked_profits -= vested_profits
	self.last_report = block.timestamp

	log UnlockProfits(vested_profits, locked_profit, self.vesting_rate)

	return vested_profits

##############################
##############################
### Conversions w/ Decimals
### N = 1e8 = PRICE_DECIMALS
### price = assets * N / supply
### supply = assets * N / price
### assets = supply * price / N
##############################
##############################

@internal
@view
def _convert_to_shares(_assets: uint256) -> uint256:
	price: uint256 = self._virtual_price()
	if price == 0: # prevent div by 0
		return 0
	return (_assets * PRICE_DECIMALS) / price # max() in _virtual_price prevents div by 0

@internal
@view
def _convert_to_assets(_shares: uint256) -> uint256:
	return (_shares * self._virtual_price() / PRICE_DECIMALS)

@view
@internal
def _virtual_price() -> uint256:
	"""
	@notice
		Uses total assets owned by vault divided by outstanding shares (liabilities) to calculate price per share
		Denominated in 8 decimals e.g. 1 token per 1 share = virtual_price of 100_000_000
	@dev
		_locked_profit is totally separate from _virtual_price
	@return
		# of assets per share. denominated in pool/asset decimals (MUST be the same)
	"""
	assets: uint256 = self._vault_assets() # cache var to save SLOAD
	if assets == 0:
		return PRICE_DECIMALS

	return (assets * PRICE_DECIMALS) / max(1, self.total_supply)

@view
@internal
def _virtual_apr() -> int256:
	# returns rate of share price increase/decrease
	# TODO RDT logic
	return 0

@view
@internal
def _calc_locked_profit() -> uint256:
	"""
	@notice
		Gets the amount of self.locked_profit is actually locked
		after accounting for tokens vested since self.last_report
	@dev
		_locked_profit is functionally totally separate from _virtual_price
	@return
		# of assets that are currently locked.
		If 0 then all of self.locked_profits are available to vest 
	"""
	pct_profit_locked: uint256 = (block.timestamp - self.last_report) * self.vesting_rate

	if(pct_profit_locked < VESTING_RATE_COEFFICIENT):
		locked_profit: uint256 = self.locked_profits
		return locked_profit - (
				pct_profit_locked
				* locked_profit
				/ VESTING_RATE_COEFFICIENT
			)
	else:
		return 0


@view
@internal
def _max_liquid_assets() -> uint256:
	"@notice total amount of assets that can be immediately withdrawn from vault"
	free_assets: uint256 = self.total_assets - self._calc_locked_profit()
	if self.total_deployed > free_assets: 
		return 0
	return free_assets - self.total_deployed

@pure
@internal
def _get_pool_name(_name: String[34]) -> String[50]:
	return concat(CONTRACT_NAME, ' - ', _name)

@pure
@internal
def _get_pool_decimals(_token: address) -> uint8:
	"""	
	@notice
		Gets the decimals for the underlying pool token so we can duplicate it according to 4626 standard
	@param _token
		Pool's asset to mimic decimals for pool's token
	"""
	asset_decimals: Bytes[32] = b""
	asset_decimals = raw_call(
		_token,
		method_id("decimals()"),
		max_outsize=32, is_static_call=True, revert_on_failure=True
	)

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
	"""
	@notice
		Gets the maximum amount of tokens someone could flash loan from this contract
	"""
	if _token != ASSET:
		return 0
	else:
		return self._max_liquid_assets()

@view
@internal
def _calc_flash_fee(_token: address, _amount: uint256) -> uint256:
	"""
	@notice
		Slight wrapper around _calc_fee to account for liquid assets that can be lent
	@dev
		MUST manually emit RevenueGenerated event when flash fee is paid
	"""
	return self._calc_fee(min(_amount, self._max_liquid_assets()), self.fees.flash)

@view
@external
def flashFee(_token: address, _amount: uint256) -> uint256:
	assert _token == ASSET
	return self._calc_flash_fee(_token, _amount)

@external
@nonreentrant("lock")
def flashLoan(
	receiver: address,
	_token: address,
	amount: uint256,
	data: Bytes[25000]
) -> bool:
	assert amount <= self._max_liquid_assets()

	# give them the flashloan
	self._erc20_safe_transfer(ASSET, msg.sender, amount)

	fee: uint256 = self._calc_flash_fee(_token, amount)
	log RevenueGenerated(msg.sender, ASSET, fee, amount, convert(FEE_TYPES.FLASH, uint256), self)

	# ensure they can receive flash loan and are ERC3156 compatible
	assert (
		keccak256("ERC3156FlashBorrower.onFlashLoan") ==
		IERC3156FlashBorrower(receiver).onFlashLoan(msg.sender, _token, amount, fee, data)
	)

	# TODO _erc20_safe_transfer_from
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

@view
@external
def asset() -> address:
	return ASSET

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
	return self._virtual_apr()

@view
@external
def price() -> uint256:
	return self._virtual_price()

@external
@view
def convertToShares(_assets: uint256) -> uint256:
	return self._convert_to_shares(_assets)

@external
@view
def convertToAssets(_shares: uint256) -> uint256:
	return self._convert_to_assets(_shares)

# TODO TEST -- all max functions assume share price > 1.
# need to account for total_supply as cap bc inflating faster than total_assets

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
	# max is always global limit bc user balance <= total supply
	return  self._convert_to_shares(max_value(uint256) - self.total_assets)

@external
@view
def maxWithdraw(_owner: address) -> uint256:
	"""
		remove shares
	"""
	return max(
		self._convert_to_assets(self.balances[_owner]),
		self._max_liquid_assets()
	)


@external
@view
def maxRedeem(_owner: address) -> uint256:
	"""
		remove assets
	"""
	return max(
		self.balances[_owner],
		self._convert_to_shares(self._max_liquid_assets())
	)

@external
@view
def previewDeposit(_assets: uint256) -> uint256:
	"""
	@notice		Returns max amount that can be deposited which is min(maxDeposit, userRequested)
				So if assets > maxDeposit then it returns maxDeposit
				
	@dev 		INCLUSIVE of self.fees.deposit (should be same as without deposit fees bc of mintflation)
				TODO? > make INCLUSIVE of self.PRICE_DECIMALS to prevent total_assets overflowing on price calculations???
	@return 	shares returned when minting _assets
	"""
	assert _assets != 0
	# TODO need if statement if share price is over/under 1. need to use total_assets vs total_supply
	# e.g. if pool.price() < PRICE_DECIMALS: (max_value(uint256) - self.total_assets) else: (max_value(uint256) - self.total_assets)
	# Dont need to include deposit fees here since they are inflationary (post deposit) they shouldnt affect return values
	return self._convert_to_shares(min(
		(max_value(uint256) - self.total_assets), 
		_assets
	))

@external
@view
def previewMint(_shares: uint256) -> uint256:
	"""
	@notice		Returns max amount that can be deposited which is min(maxDeposit, userRequested)
				So if assets > maxDeposit then it returns maxDeposit
				
	@dev 		INCLUSIVE of self.fees.deposit (should be same as without deposit fees bc of mintflation)
				TODO? > make INCLUSIVE of self.PRICE_DECIMALS to prevent total_assets overflowing on price calculations???
	@return 	assets required to mint _shares
	"""
	assert _shares != 0
	# TODO need if statement if share price is over/under 1. need to use total_assets vs total_supply
	# e.g. if pool.price() < PRICE_DECIMALS: (max_value(uint256) - self.total_supply) else: (max_value(uint256) - self.total_assets)
	# Dont need to include deposit fees here since they are inflationary (post deposit) they shouldnt affect return values
	return self._convert_to_assets(min(
		(max_value(uint256) - self.total_supply),
		_shares
	))

@external
@view
def previewWithdraw(_assets: uint256) -> uint256:
	"""
	@return 	shares you need to burn to receive _assets back when withdrawing
	"""
	assert _assets != 0
	# TODO need if statement if share price is over/under 1. need to use total_assets vs total_supply
	# e.g. if pool.price() < PRICE_DECIMALS: (max_value(uint256) - self.total_assets) else: (max_value(uint256) - self.total_supply)
	# TODO include withdraw fees to assets 
	shares: uint256 = self._convert_to_shares(_assets)
	return shares + self._convert_to_shares(self._calc_fee(shares, self.fees.withdraw))


@view
@external
def previewRedeem(_shares: uint256) -> uint256:
	"""
	@return 	assets you would receive for redeeming _shares
	"""
	assert _shares != 0
	# TODO need if statement if share price is over/under 1. need to use total_assets vs total_supply
	# e.g. if pool.price() < PRICE_DECIMALS: return self._convert_to_assets(max_redeemabl else: return self._convert_to_assets(max_redeemabl
	# TODO FIX withdraw fees
	return self._convert_to_assets(_shares) - self._convert_to_assets(self._calc_fee(_shares, self.fees.withdraw))


### Pool view

@view
@external
def free_profit() -> uint256:
	"""
	@notice
		Amount of profit that can currently be vested into pool share price
	"""
	return self.locked_profits - self._calc_locked_profit()

@view
@internal
def _vault_assets() -> uint256:
	"""
	@notice
		Not ur keys, not ur coins.
		Includes all assets held within pool including locked_profits. 
		Excludes all assets deposited in external contracts
	@return
		Total amount of assets cryptographically owned by this contract
	"""
	return self.total_assets - self._calc_locked_profit()



@view
@external
def vault_assets() -> uint256:
	"""
	@notice
		Not ur keys, not ur coins.
		Includes all assets held within pool including locked_profits. 
		Excludes all assets deposited in external contracts
	@return
		Total amount of assets cryptographically owned by this contract
	"""
	return self._vault_assets()


@view
@external
def liquid_assets() -> uint256:
	"""
	@notice
		All available assets currently held inside the pool
		that can be withdrawn by depositors
		x = total_assets - total_deployed - locked_profit
	@return
		All available assets that can be withdrawn by depositors
	"""
	return self._max_liquid_assets()





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

	def asset() -> address: view

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

interface ISecuredLine:
	def borrower() -> address: pure
	def ids(index: uint256) -> bytes32: view
	def status() -> uint8: view
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
	def setRates(id: bytes32, drate: uint128, frate: uint128): nonpayable
	def increaseCredit(id: bytes32,  amount: uint256): payable

	# self-repay
	def useAndRepay(amount: uint256) -> bool: nonpayable
	def depositAndRepay(amount: uint256): nonpayable

	# divest
	def withdraw(id: bytes32,  amount: uint256): nonpayable

	# leverage
	def borrow(id: bytes32,  amount: uint256): nonpayable

### Events

# IERC20 Events
event Transfer:
	sender: indexed(address)
	receiver: indexed(address)
	amount: uint256

event Approval:
	owner: indexed(address)
	spender: indexed(address)
	amount: uint256

# IERC4626 Events
event Deposit:
	shares: uint256
	owner: indexed(address)
	sender: indexed(address)
	assets: uint256

event Withdraw:
	shares: uint256
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
	amount: uint256
	remaining: uint256
	vesting_rate: indexed(uint256)

# Investing Events
event Impair:
	line: indexed(address)		# line of credit contract that we invested in
	position: indexed(bytes32)	# the id for our position on the line
	# good news first
	recovered_deposit: uint256 	# amount of tokens we deposited in position but werent borrowed at time of impairment 
	interest_earned: uint256	# amount of interest previously paid by borrower we collected when exiting position
	# now the bad news
	fees_burned: uint256 		# amount of owner shares to burn to repay loss to pool
	net_asset_loss: uint256		# how many tokens pool share holders lost in aggregate after burned fees.
	realized_loss: uint256 		# notional token amount of borrower debt at time of impairment

event InvestVault:
	vault: indexed(address)
	assets: uint256
	shares: uint256

event DivestVault:
	vault: indexed(address)
	assets: uint256
	shares: uint256
	profit_or_loss: uint256 # how many assets we realized as losses or gained (NOT YET realized) as profit when divesting
	is_profit: indexed(bool)

# fees

event FeeSet:
	fee_bps: uint16
	fee_type: indexed(uint256)

event NewPendingRevRecipient:
	new_recipient: indexed(address) 	# New active management fee

event AcceptRevRecipient:
	new_recipient: indexed(address) 	# New active management fee

event RevenueGenerated:		# standardize revenue reporting for offchain analytics
	payer: indexed(address) # where fees are being paid from
	token: address 			# tokens fees were paid in
	revenue: uint256 		# actual fees generated to `receiver` from assets
	amount: uint256			# total assets that fees were generated on (user deposit, flashloan, loan principal, etc.)
	fee_type: indexed(uint256) # maps to app specific fee enum or eventually some standard fee code system
	receiver: indexed(address) # who is getting the fees paid

event RevenueClaimed:
	rev_recipient: indexed(address)
	amount: uint256

# Admin updates

event NewPendingOwner:
	new_recipient: indexed(address)

event AcceptOwner:
	new_recipient: indexed(address) # New active governance

event UpdateMinDeposit:
	minimum: uint256 # New active deposit limit

event UpdateMaxAssets:
	maximum: uint256 # New active deposit limit

event Sweep:
	token: indexed(address) # New active deposit limit
	amount: uint256 # New active deposit limit

event UpdateProfitVestingRate:
	degredation: uint256

event StakeAssets:
	staker: address
	assets: uint256
	shares: uint256

event InitiateUnstake:
	unlock_block: uint256 
	shares: uint256

event UnstakeShares:
	unlock_block: uint256 
	shares: uint256

# Testing events
event named_uint:
	str: String[200]
	num: indexed(uint256)

event named_addy:
	str: String[200]
	addy: indexed(address)
