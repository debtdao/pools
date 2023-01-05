# @version ^0.3.7

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


# IERC20 vars
name: public(immutable(String[50]))
symbol: public(immutable(String[18]))
decimals: public(immutable(uint8))
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
# minimum amount of assets that can be deposited at once. whales only, fuck plebs.
min_deposit: public(uint256)
# maximum amount of asset deposits to allow into pool
max_assets: public(uint256)
# amount of asset held externally in lines or vaults
total_deployed: public(uint256)
# shares earned by Delegate for managing pool
accrued_fees: public(uint256)

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
  	delegate_: address,
	asset_: address,
	name_: String[34],
	symbol_: String[16],
	fees_: Fees,
):
	"""
	@dev configure data for contract owners and initial revenue contracts.
		Owner/operator/treasury can all be the same address
	@param delegate_	who will own and control the pool
	@param asset_ 		ERC20 token to deposit and lend. Must verify asset is supported by oracle on Lines you want to invest in.
	@param name_ 		custom pool name. first 0-13 chars are templated  "Debt DAO Pool - {name_}"
	@param symbol_ 		custom pool symbol. first 5 chars are templated  "dd{token.symbol}-{symbol_}"
	@param fees 		fees to charge on pool
	"""
	self.owner = msg.sender # set owner to deployer for validation functions
	assert delegate_ != empty(address)
	assert self._assert_max_fee(fees_.performance, FEE_TYPES.PERFORMANCE) # max 100% performance fee
	assert self._assert_pittance_fee(fees_.collector, FEE_TYPES.COLLECTOR)
	assert self._assert_pittance_fee(fees_.flash, FEE_TYPES.FLASH)
	assert self._assert_pittance_fee(fees_.referral, FEE_TYPES.REFERRAL)
	assert self._assert_pittance_fee(fees_.deposit, FEE_TYPES.DEPOSIT)
	assert self._assert_pittance_fee(fees_.withdraw, FEE_TYPES.WITHDRAW)

	# Setup Pool variables
	self.owner = delegate_
	self.fees = fees_

	# IERC20 vars
	# TODO templatize name/symbol
	# anme = CONTRACT_NAME + '-' +  name_ = 'Debt DAO Pool - Maven11 DAI'
	name = self._get_pool_name(name_)
	# symbol = 'dd' + IERC20Detailed(asset_).symbol + '-' + symbol_ = 'ddDAI-MVN11'
	symbol = self._get_pool_symbol(symbol_)

	# 4626 recommendation is to mimic decimals of underlying assets so less likely to be conversion errors
	# TODO what happens if asset_ hs no decimals? revert if decimals fails
	decimals = IERC20Detailed(asset_).decimals()
	# IERC4626
	asset = asset_

	#ERC2612
	CACHED_CHAIN_ID = chain.id
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
	
	# no need to log, Line emits events already
	return ISecuredLine(line).addCredit(drate, frate, amount, asset, self)

@external
@nonreentrant("lock")
def increase_credit(line: address, id: bytes32, amount: uint256) -> bool:
	self._assert_delegate_has_available_funds(amount)

	self.total_deployed += amount
	
	# no need to log, Line emits events already
	return ISecuredLine(line).increaseCredit(id, amount)

@external
def set_rates(line: address, id: bytes32, drate: uint128, frate: uint128) -> bool:
	assert msg.sender == self.owner
	# no need to log, Line emits events already
	return ISecuredLine(line).setRates(id, drate, frate)

@external
@nonreentrant("lock")
def collect_interest(line: address, id: bytes32) -> uint256:
  return self._reduce_credit(line, id, 0)[1]

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

	# no need to log, Line emits events already
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
	fees_burned: uint256 = 0

	# If available, take performance fee from delegate to offset impairment and protect depositors
	# TODO currently callable by anyone. Give % of delegates fees to caller for impairing?
	if self.accrued_fees >= position.principal:
		fees_burned = position.principal / share_price

		# burn fees to offset losses
		self.accrued_fees -= fees_burned
		self.total_supply -= fees_burned
		# doesnt reducing supply mean share price goes UP during impairment?
	else:
		# else take what we can from delegate and socialize losses
		fees_burned = self.accrued_fees
		self.total_supply -= fees_burned # burn what fees we can
		self._update_shares(position.principal - (fees_burned * share_price), True)
		self.accrued_fees = 0

	# we deduct lost principal but add gained interest
	if position.interestRepaid != 0:
		self._update_shares(position.interestRepaid)

	# snitch was successful
	if fees_burned != 0 and msg.sender != self.owner:
		self._calc_and_mint_fee(self, msg.sender, fees_burned, SNITCH_FEE, FEE_TYPES.SNITCH)

	log Impair(id, recoverable, position.principal, old_apr, self._get_share_APR(), share_price, fees_burned)

	return (recoverable, position.principal)

### External 4626 vault investing

@external
@nonreentrant("lock")
def invest_4626(vault: address, amount: uint256) -> uint256:
	self._assert_delegate_has_available_funds(amount)

	self.total_deployed += amount
	# TODO add to vaults[vault] += amount

	# TODO check previewDeposit expected vs deposit actual for slippage
	shares: uint256 = IERC4626(vault).deposit(amount, self)

	log Invest4626(vault, amount, shares) ## TODO shares
	return shares


@external
@nonreentrant("lock")
def divest_4626(vault: address, amount: uint256) -> bool:
	assert msg.sender == self.owner
	self.total_deployed += amount

	# TODO check previewWithdraw expected vs withdraw actual for slippage
	IERC4626(vault).withdraw(amount, self, self)

	# TODO how do we tell what is principal and what is profit??? need to update total_assets with yield
	# TBH a wee bit tracky to track all the different places they invested, entry price(s) for each, exit price(s) for each, calc profit over time, etc.
	log Divest4626(vault, amount, 0)
	# if balance of 4626 token is 0 but vaults[vault] > 0 then impair(vaults[vault])

	# delegate doesnt earn fees on 4626 strategies to incentivize line investment
	return True


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


### ERC4626 Functions
@external
@nonreentrant("lock")
def deposit(assets: uint256, receiver: address) -> uint256:
	"""
		@returns - shares
	"""
	return self._deposit(assets, receiver)

@external
@nonreentrant("lock")
def depositWithReferral(assets: uint256, receiver: address, referrer: address) -> uint256:
	"""
		@returns - shares
	"""
	return self._deposit(assets, receiver, referrer)

@external
@nonreentrant("lock")
def mint(shares: uint256, receiver: address) -> uint256:
	"""
		@returns - assets
	"""
	share_price: uint256 = self._get_share_price()
	return self._deposit(shares * share_price, receiver) * share_price

@external
@nonreentrant("lock")
def mintWithReferral(shares: uint256, receiver: address, referrer: address) -> uint256:
	"""
		@returns - assets
	"""
	share_price: uint256 = self._get_share_price()
	return self._deposit(shares * share_price, receiver, referrer) * share_price

@external
@nonreentrant("lock")
def withdraw(
	assets: uint256,
	receiver: address,
	owner: address
) -> uint256:
	"""
		@returns - shares
	"""
	return self._withdraw(assets, owner, receiver)

@external
@nonreentrant("lock")
def redeem(shares: uint256, receiver: address, owner: address) -> uint256:
	"""
		@returns - assets
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
	if sender != empty(address):
		# if not minting, then ensure sender has balance
		self.balances[sender] -= amount
	
	if receiver != empty(address):
		# if not burning, add to receiver
		# on burns shares dissapear but we still have logs
		self.balances[receiver] += amount
	

	log Transfer(sender, receiver, amount)
	return True

@internal
def _caller_has_approval(owner: address, amount: uint256) -> bool:
	if msg.sender != owner:
		allowance: uint256 = self.allowances[owner][msg.sender]
		# MAX = unlimited approval (saves an SSTORE)
		if (allowance < max_value(uint256)):
			allowance = allowance - amount
			self.allowances[owner][msg.sender] = allowance
			# NOTE: Allows log filters to have a full accounting of allowance changes
			log Approval(owner, msg.sender, allowance)

	return True

@internal
def erc20_safe_transfer(token: address, receiver: address, amount: uint256):
    # Used only to send tokens that are not the type managed by this Vault.
    # HACK: Used to handle non-compliant tokens like USDT
    response: Bytes[32] = raw_call(
        token,
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
def _mint(to: address, shares: uint256) -> bool:
	"""
	"""
	self.total_supply += shares
	self._transfer(empty(address), to, shares)
	return True

@internal
def _burn(owner: address, shares: uint256) -> bool:
	"""
	"""
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
			# store delegate fees so we can slash if neccessary
			assert self._mint(self, fees)
			self.accrued_fees += fees
		else:
			# mint other ecosystem participants fees to them directly
			assert self._mint(to, fees)
		
	log FeesGenerated(payer, to, fees, shares, feeType)
	return fees


@internal
@pure
def _calc_fee(shares: uint256, fee: uint16) -> uint256:
	"""
	"""
	if fee == 0:
		return 0
	else:
		return (shares * convert(fee, uint256)) / convert(FEE_COEFFICIENT, uint256)

@internal 
def _reduce_credit(line: address, id: bytes32, amount: uint256) -> (uint256, uint256):
	"""
	@notice		withdraw deposit and/or interest from an external position
	@returns 	(initial principal withdrawn, usurious interest earned)
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
	# @dev MUST come after `amount` shorthand checks
	if withdrawable < interest:
		# if we want less than claimable interest, reduce incoming interest
		interest = withdrawable
		deposit = 0
	else:
		# we are withdrawing initial deposit in addition to interest
		deposit = withdrawable - interest
		# TODO TEST this random side effect here
		self.total_deployed -= deposit # return principal to liquid pool

	# no need to log, Line emits events already
	assert ISecuredLine(line).withdraw(id, withdrawable)

	if interest != 0:
		# update share price with new profits
		self._update_shares(interest, False)

		# payout fees with new share price
		# TODO TEST does taking fees before/after updating shares affect RDT ???
		fees: uint256 = self._take_performance_fee(interest)

	return (deposit, interest)

@internal
def _take_performance_fee(interest_earned: uint256) -> uint256:
	"""
		@notice takes total profits earned and takes fees for delegate and compounder
		@dev fees are stored as shares but input/ouput assets
		@param interest_earned - total amount of assets claimed from usurious activities
		@return total amount of assets taken as fees
	"""
	share_price: uint256 = self._get_share_price()
	shares_earned: uint256 = interest_earned / self._get_share_price()

	performance_fee: uint256 = self._calc_and_mint_fee(self, self.owner, shares_earned, self.fees.performance, FEE_TYPES.PERFORMANCE)

	collector_fee: uint256 = self._calc_fee(shares_earned, self.fees.collector)
	if (collector_fee != 0 and msg.sender != self.owner):
		# only _calc not _mint_and_calc so caller gets collector fees in raw asset for easier mev
		log FeesGenerated(self, msg.sender, collector_fee, shares_earned, FEE_TYPES.COLLECTOR)
		self.total_assets -= collector_fee * share_price # use pre-performance fee inflation price for payout
		self.erc20_safe_transfer(asset, msg.sender, collector_fee)

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
	
	# inc internal supply with new assets deposited and shares minted
	# use original price, opposite of _withdraw, requires them to deposit more assets than current price post fee inflation
	self.total_assets += assets
	self._mint(receiver, shares)

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

	# TODO test how  withdraw fee inflatino affects the shares/asssets that they are *supposed* to lose
		
	# use _calc not _mint_and_calc. minting does not affect withdrawer who should be penalized, only other pool depositors.
	# make them burn extra shares instead of inflating
	withdraw_fee: uint256 = self._calc_fee(shares, self.fees.withdraw)
	if self.fees.withdraw != 0: # only log if fee needed
		log FeesGenerated(receiver, self.owner, withdraw_fee, shares,  FEE_TYPES.WITHDRAW)

	#  remove assets/shares from pool
	self.total_assets -= assets
	self._burn(receiver, shares + withdraw_fee)
	
	#  transfer assets to withdrawer
	self.erc20_safe_transfer(asset, receiver, assets)

	log Withdraw(shares, owner, receiver, msg.sender, assets)
	log TrackSharePrice(share_price, share_price, self._get_share_APR())

	return shares


@internal
def _update_shares(amount: uint256, impair: bool = False):
	share_price: uint256 = self._get_share_price()

	if impair:
		self.total_assets -= amount
		# TODO RDT logic
		# TODO  log RDT rate change
	else:
		self.total_assets += amount
		# TODO RDT logic
		# TODO  log RDT rate change

	# log price change after updates
	log TrackSharePrice(share_price, self._get_share_price(), self._get_share_APR())


@view
@internal
def _get_share_price() -> uint256:
	# returns # of assets per share

	# TODO RDT logic
	return self.total_assets / self.total_supply

@view
@internal
def _get_share_APR() -> int256:
	# returns rate of share price increase/decrease
	# TODO RDT logic
	return 0

@view
@internal
def _get_max_liquid_assets() -> uint256:
	# TODO account for RDT locked profits
	return self.total_assets - self.total_deployed

@pure
@internal
def _get_pool_name(name_: String[34]) -> String[50]:
	return concat(CONTRACT_NAME, ' - ', name_)


@pure
@internal
def _get_pool_decimals(token: address) -> uint8:
	"""
	@dev 		 		if we dont directly copy the `asset`'s decimals then we need to do decimal conversions everytime we calculate share price
	@param token 		pool's asset to mimic decimals for pool's token
	"""
	success: bool = False
	asset_decimals: Bytes[8] = b""
	success, asset_decimals = raw_call(
		token,
		_abi_encode(b"",method_id=method_id("decimals()")),
		max_outsize=8,
		is_static_call=True,
		revert_on_failure=False
	)

	if success:
		return convert(asset_decimals, uint8)
	else:
		return 18

@pure
@internal
def _get_pool_symbol(symbol_: String[16]) -> String[18]:
	"""
	@dev 		 		if we dont directly copy the `asset`'s decimals then we need to do decimal conversions everytime we calculate share price
	@param symbol_	 	custom symbol input by pool creator
	"""
	return concat("dd", symbol_)


# IERC 3156 Flash Loan functions

@view
@external
def maxFlashLoan(token: address) -> uint256:
	if token != asset:
		return 0
	else:
		return self._get_max_liquid_assets()

@view
@internal
def _getFlashFee(token: address, amount: uint256) -> uint256:
	if self.fees.flash == 0:
		return 0
	else:
		return self._get_max_liquid_assets() * convert(self.fees.flash / FEE_COEFFICIENT, uint256)

@view
@external
def flashFee(token: address, amount: uint256) -> uint256:
	assert token == asset
	return self._getFlashFee(token, amount)

@external
@nonreentrant("lock")
def flashLoan(
	receiver: address,
	token: address,
	amount: uint256,
	data: Bytes[25000]
) -> bool:
	assert amount <= self._get_max_liquid_assets()

	# give them the flashloan
	self.erc20_safe_transfer(asset, msg.sender, amount)

	fee: uint256 = self._getFlashFee(token, amount)
	
	# ensure they can receive flash loan
	# TODO says onFlashLoan not on interface
	assert IERC3156FlashBorrower(receiver).onFlashLoan(msg.sender, token, amount, fee, data) == keccak256("ERC3156FlashBorrower.onFlashLoan")
	
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
def convertToShares(assets: uint256) -> uint256:
	return assets * (self.total_assets / self.total_supply)


@external
@view
def convertToAssets(shares: uint256) -> uint256:
	return shares * (self.total_supply / self.total_assets)


@external
@view
def maxDeposit(receiver: address) -> uint256:
	"""
		add assets
	"""
	return max_value(uint256) - self.total_assets

@external
@view
def maxMint(receiver: address) -> uint256:
	return (max_value(uint256) - self.total_assets) / self._get_share_price()

@external
@view
def maxWithdraw(owner: address) -> uint256:
	"""
		remove shares
	"""
	return self._get_max_liquid_assets()


@external
@view
def maxRedeem(owner: address) -> uint256:
	"""
		remove assets
	"""
	return self._get_max_liquid_assets() / self._get_share_price()

@external
@view
def previewDeposit(assets: uint256) -> uint256:
	"""
	@notice		Returns max amount that can be deposited which is min(maxDeposit, userRequested)
				So if assets > maxDeposit then it returns maxDeposit
	@dev 
	"""
	share_price: uint256 =  self._get_share_price()
	free_shares: uint256 = min(max_value(uint256) - self.total_assets, assets) / share_price
	# TODO Dont think we need to include fees here since they are inflationary they shouldnt affect return values
	return free_shares - self._calc_fee(assets / share_price, self.fees.deposit)

@external
@view
def previewMint(shares: uint256) -> uint256:
	share_price: uint256 =  self._get_share_price()
	free_shares: uint256 = min(max_value(uint256) - self.total_assets, shares * share_price)
	# TODO Dont think we need to include fees here since they are inflationary they shouldnt affect return values
	return (free_shares - self._calc_fee(free_shares, self.fees.deposit)) * share_price

@external
@view
def previewWithdraw(assets: uint256) -> uint256:
	share_price: uint256 =  self._get_share_price()
	free_shares: uint256 = min(self._get_max_liquid_assets(), (max_value(uint256) - assets)) / share_price
	# TODO Dont think we need to include fees here since they are inflationary they shouldnt affect return values
	return free_shares - self._calc_fee(assets / share_price, self.fees.withdraw)

@external
@view
def previewRedeem(shares: uint256) -> uint256:
	share_price: uint256 =  self._get_share_price()
	free_shares: uint256 = min(self._get_max_liquid_assets(), shares * share_price)
	# TODO Dont think we need to include fees here since they are inflationary they shouldnt affect return values
	return (free_shares - self._calc_fee(free_shares, self.fees.withdraw)) * share_price


### Interfaces

from vyper.interfaces import ERC20 as IERC20

interface IERC2612:
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
	owner: address # New active governance

event UpdateMinDeposit:
	depositLimit: uint256 # New active deposit limit

event UpdateMaxAssets:
	assetLimit: uint256 # New active deposit limit
