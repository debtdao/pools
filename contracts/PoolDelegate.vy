# version 0.3.7

# standard ERC interfaces we implelement
from vyper.interfaces import ERC20 as IERC20
import interfaces.IERC4626 as IERC4626
import interfaces.IERC2612 as IERC2612
import interfaces.IERC3156 as IERC3156
import interfaces.IPoolDelegate as IPoolDelegate

# External contracts we interact with
import interfaces.ISecuredLine as ISecuredLine
# import interfaces.IERC3156FlashBorrower as IERC3156FlashBorrower
interface IERC3156FlashBorrower:
    def onFlashLoan(
        initiator: address,
        token: address,
        amount: uint256,
        fee: uint256,
        data:  Bytes[25000]
    ) -> bytes32: payable


# implements: [IERC20, IERC20Detailed, IERC2612, IERC4626, IERC3156, PoolDelegate]
implements: IERC20
implements: IERC2612
implements: IERC4626
implements: IERC4626
implements: IERC3156
implements: IPoolDelegate
	
# Constants

# @notice LineLib.STATUS.INSOLVENT
INSOLVENT_STATUS: constant(uint256) = 4
# @notice 100% in bps. Used to divide after multiplying bps fees. Also max performance fee.
FEE_COEFFICIENT: constant(uint16) = 10000
# @notice 5% in bps. Max fee that can be charged for non-performance fee
MAX_PITTANCE_FEE: constant(uint16) = 500
# @notice EIP712 contract name
CONTRACT_NAME: constant(String[18]) = "Debt DAO Pool"
# @notice EIP712 contract version
API_VERSION: constant(String[18]) = "0.0.1"
# @notice EIP712 type hash
DOMAIN_TYPE_HASH: constant(bytes32) = keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
# @notice EIP712 permit type hash
PERMIT_TYPE_HASH: constant(bytes32) = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")


# IERC20 vars
name: public(immutable(String[50]))
symbol: public(immutable(String[18]))
decimals: public(immutable(uint8))
# total amount of shares in pool
totalSupply: public(uint256)
# balance of pool vault shares
balances: HashMap[address, uint256]
# owner -> spender -> amount approved
allowances: HashMap[address, HashMap[address, uint256]]

# IERC4626 vars
# underlying token for pool/vault
asset: public(immutable(address))
# total notional amount of underlying token held in pool
totalAssets: public(uint256)

# EIP 2612 Variables
nonces: public(HashMap[address, uint256])
# cheap retrieval of domain separator if no chainforks
CACHED_CHAIN_ID: public(immutable(uint256))
CACHED_COMAIN_SEPARATOR: public(immutable(bytes32))


# Pool Variables

# asset manager who directs funds into investment strategies
delegate: public(address)
# address to migrate delegate powers to. Must be accepted before transfer occurs
pendingDelegate: public(address)
# address that can came delegates fees
feeRecipient: public(address)
# minimum amount of assets that can be deposited at once. whales only, fuck plebs.
minDeposit: public(uint256)
# amount of asset held externally in lines or vaults
totalDeployed: public(uint256)
# shares earned by Delegate for managing pool
accruedFees: public(uint256)

struct Fees:
	# % (in bps) of profit that delegate keeps as incentives
	performance: uint16
	# % (in bps) of performance fee to give to caller for automated collections
	collector: uint16
	# % fee (in bps) to charge flash borrowers
	flash: uint16
	# % fee (in bps) to charge flash borrowers
	referral: uint16
	# % fee (in bps) to charge pool depositors
	deposit: uint16
	# % fee (in bps) to charge flash borrowers
	withdraw: uint16

fees: public(Fees)


@external
def __init__(
  	delegate_: address,
	asset_: address,
	fee: uint16,
	name_: String[50],
	symbol_: String[18]
):
	"""
	@dev configure data for contract owners and initial revenue contracts.
		Owner/operator/treasury can all be the same address
	@param
	"""
	# IERC20 vars
	name = name_
	symbol = symbol_
	# 4626 recommendation is to mimic decimals of underlying assets so less likely to be conversion errors
	decimals = IERC4626(asset_).decimals()
	# IERC4626
	asset = asset_

	#ERC2612
	CACHED_CHAIN_ID = chain.id
	CACHED_COMAIN_SEPARATOR = self.domain_separator()

	# DelegatePool
	self.delegate = delegate_
	self.fees.performance = self._validateFee(fee)



# Delegate functions

## Investing functions
@external
def addCredit(
  line: address,
  drate: uint128,
  frate: uint128,
  amount: uint256
) -> bytes32:
	assert msg.sender == self.delegate
	self.totalDeployed += amount
	return ISecuredLine(line).addCredit(drate, frate, amount, asset, self)

@external
def increaseCredit(
  line: address,
  id: bytes32,
  amount: uint256
) -> bool:
	assert msg.sender == self.delegate
	self.totalDeployed += amount
	return ISecuredLine(line).increaseCredit(id, amount)

@external
@nonreentrant("lock")
def invest4626(vault: address, amount: uint256) -> uint256:
	assert msg.sender == self.delegate
	self.totalDeployed += amount
	# TODO check previewDeposit expected vs deposit actual for slippage
	shares: uint256 = IERC4626(vault).deposit(amount, self)
	log Invest4626(vault, amount, shares) ## TODO shares
	return shares

@external
def sweep(token: address, receiver: address) -> uint256:
	assert msg.sender == self.delegate
	assert token != asset
	sweepable: uint256 = IERC20(token).balanceOf(self)
	assert IERC20(token).transfer(receiver, sweepable)
	return sweepable

@internal 
def _reduceCredit(line: address, id: bytes32, amount: uint256) -> uint256:
	withdrawable: uint256 = amount
	interest: uint256 = 0
	deposit: uint256 = 0
	(interest, deposit) = ISecuredLine(line).available(id)
	if amount == 0:
		# 0 is shorthand for take maximum amount of interest
		withdrawable = interest
	elif amount == max_value(uint256):
		# MAX is shorthand for all assets
		withdrawable = deposit + interest


	# @dev MUST come after `amount == 0` check
	if withdrawable < interest:
		# if we want less than claimable interest, reduce incoming interest
		interest = withdrawable

	ISecuredLine(line).withdraw(id, withdrawable)

	# update token balances and share price with new profits
	self._updateShares(interest, False)

	# payout fees with new share price
	# TODO does taking fees before/after updating shares affect RDT ???
	fees: uint256 = self._takePerformanceFees(interest)

	return interest - fees

@external
@nonreentrant("lock")
def collectInterest(line: address, id: bytes32) -> uint256:
  return self._reduceCredit(line, id, 0)

## Divestment functions

@external
@nonreentrant("lock")
def reduceCredit(
	line: address,
	id: bytes32,
	amount: uint256
) -> bool:
	assert msg.sender == self.delegate

	interestCollected: uint256 = self._reduceCredit(line, id, amount)
	# reduce principal deployed
	# TODO might b wrong math
	self.totalDeployed -= amount - interestCollected
	return True

@external
@nonreentrant("lock")
def claimAndRepay(line: address, claimToken: address, tradeData: Bytes[50000]) -> uint256:
	assert msg.sender == self.delegate
	# Assume we are next lender in queue. 
	# save id for later incase we fully repay and close
	id: bytes32 = ISecuredLine(line).ids(0)
	repaid: uint256 = ISecuredLine(line).claimAndRepay(claimToken, tradeData)

	# collect all available interest payments
	self._reduceCredit(line, id, 0)

	return repaid

@external
@nonreentrant("lock")
def useAndRepay(line: address, amount: uint256) -> bool:
	assert msg.sender == self.delegate
	# Assume we are next lender in queue. 
	# save id for later internal functions incase we repay
	id: bytes32 = ISecuredLine(line).ids(0)
	assert ISecuredLine(line).useAndRepay(amount)

	# collect all available interest payments
	self._reduceCredit(line, id, 0)

	return True

@external
@nonreentrant("lock")
def divest4626(vault: address, amount: uint256) -> bool:
	assert msg.sender == self.delegate
	self.totalDeployed -= amount
	# TODO check previewWithdraw expected vs withdraw actual for slippage
	IERC4626(vault).withdraw(amount, self, self)

	# TODO how do we tell what is principal and what is profit??? need to update totalAssets with yield
	# TBH a wee bit tracky to track all the different places they invested, entry price(s) for each, exit price(s) for each, calc profit over time, etc.
	log Divest4626(vault, amount, 0)
	# delegate doesnt earn fees on 4626 strategies to incentivize line investment
	return True

@external
@nonreentrant("lock")
def impair(line: address, id: bytes32) -> bool:
	"""
	@notice     - allows Delegate to markdown the value of a defaulted loan reducing vault share price.
	@param line - line of credit contract to call
	@param id   - credit position on line controlled by this pool 
	"""
	assert ISecuredLine(line).status() == INSOLVENT_STATUS

	position: Position = ISecuredLine(line).credits(id)

	claimable: uint256 = position.interestRepaid + (position.deposit - position.principal) # all funds left in line

	diff: uint256 = position.deposit
	if claimable > 0:
		ISecuredLine(line).withdraw(id, claimable)
		diff = position.principal - claimable  # reduce diff by recovered funds

	# TODO take performanceFee from delegate to offset impairment and reduce diff
	# TODO currently callable by anyone. Should we give % of delegates fees to caller for impairing?

	self._updateShares(diff, True)
	return True

## Maitainence functions

@external
def setRates(
  line: address,
  id: bytes32,
  drate: uint128,
  frate: uint128,
) -> bool:
	assert msg.sender == self.delegate
	# ISecuredLine(line).setRates(id, drate, frate)
	return True

@external
def updateMinDeposit(newMin: uint256)  -> bool:
	assert msg.sender == self.delegate
	self.minDeposit = newMin
	log UpdateMinDeposit(newMin)
	return True

@external
def updateDelegate(pendingDelegate_: address) -> bool:
	assert msg.sender == self.delegate
	self.pendingDelegate = pendingDelegate_
	log NewPendingDelegate(pendingDelegate_)
	return True

@external
def acceptDelegate() -> bool:
	assert msg.sender == self.pendingDelegate
	self.delegate = self.pendingDelegate
	log UpdateDelegate(self.pendingDelegate)
	return True

# manage fees


@internal 
def _validatePittanceFee(fee: uint16) -> bool:
	if fee <= MAX_PITTANCE_FEE:
		return True
	else:
		return False

@external
@nonreentrant("lock")
def updatePerformanceFee(fee: uint16) -> bool:
  assert msg.sender == self.delegate
  assert fee <= FEE_COEFFICIENT # max 100% performance fee
  self.fees.performance = fee
  log UpdatePerformanceFee(fee)
  return True

@external
@nonreentrant("lock")
def updateFlashFee(fee: uint16) -> bool:
  assert msg.sender == self.delegate
  assert self._validatePittanceFee(fee)
  self.fees.flash = fee
  log UpdateFlashFee(fee)
  return True

@external
@nonreentrant("lock")
def updateCollectorFee(fee: uint16) -> bool:
  assert msg.sender == self.delegate
  assert self._validatePittanceFee(fee)
  self.fees.collector = fee
  log UpdateCollectorFee(fee)
  return True

@external
@nonreentrant("lock")
def updateDepositFee(fee: uint16) -> bool:
  assert msg.sender == self.delegate
  assert self._validatePittanceFee(fee)
  self.fees.deposit = fee
  log UpdateReferralFee(fee)
  return True

@external
@nonreentrant("lock")
def updateWithdrawFee(fee: uint16) -> bool:
  assert msg.sender == self.delegate
  assert self._validatePittanceFee(fee)
  self.fees.withdraw = fee
  log UpdateWithdrawFee(fee)
  return True

@external
def updateFeeRecipient(newRecipient: address) -> bool:
  assert msg.sender == self.feeRecipient or msg.sender == self.delegate
  self.feeRecipient = newRecipient
  log UpdateFeeRecipient(newRecipient)
  return True

@external
@nonreentrant("lock")
def claimFees(amount: uint256) -> bool:
	assert msg.sender == self.feeRecipient
	
	# TODO check rate of change not share price
	# apr = self._getShareAPR()
	# assert apr > 0
	claimed: uint256 = amount
	# set max
	if amount == max_value(uint256):
		claimed = self.accruedFees
	
	self.accruedFees -= claimed
	self._transfer(self, msg.sender, claimed)

	log ClaimPerformanceFee(self.feeRecipient, claimed, self._getShareAPR(), self._getSharePrice())
	return True


# 4626 action functions
@external
@nonreentrant("lock")
def deposit(assets: uint256, receiver: address) -> uint256:
	"""
		adds assets
	"""
	return self._deposit(assets, receiver, empty(address))

@external
@nonreentrant("lock")
def depositWithReferral(assets: uint256, receiver: address, referrer: address) -> uint256:
	"""
		adds shares
	"""
	return self._deposit(assets, receiver, referrer)

@external
@nonreentrant("lock")
def mint(shares: uint256, receiver: address) -> uint256:
	"""
		adds shares
	"""
	return self._deposit(shares * self._getSharePrice(), receiver, empty(address))

@external
@nonreentrant("lock")
def mintWithReferral(shares: uint256, receiver: address, referrer: address) -> uint256:
	"""
		adds shares
	"""
	return self._deposit(shares * self._getSharePrice(), receiver, referrer)

@external
@nonreentrant("lock")
def withdraw(
	assets: uint256,
	receiver: address,
	owner: address
) -> uint256:
  	return self._withdraw(assets, owner, receiver)

@external
@nonreentrant("lock")
def redeem(shares: uint256, receiver: address, owner: address) -> uint256:
	"""
		adds shares
	"""
	return self._withdraw(shares * self._getSharePrice(), owner, receiver)



# pool interals

@internal
def _deposit(
	assets: uint256,
	receiver: address,
	referrer: address
) -> uint256:
	"""
		adds shares to a user after depositing into vault
		priviliged internal func
	"""
	assert assets >= self.minDeposit
	
	sharePrice: uint256 = self._getSharePrice()
	referralFee: uint256 = 0

	if referrer != empty(address) and self.fees.referral > 0:
		referralFee = (assets * convert(self.fees.referral / FEE_COEFFICIENT, uint256)) / sharePrice
		self.balances[referrer] += referralFee

	self.totalAssets += assets
	shares: uint256 = (assets / sharePrice) - referralFee
	self.balances[receiver] += shares

	assert IERC20(asset).transferFrom(msg.sender, self, assets)

	log Deposit(shares, receiver, msg.sender, assets)
	return shares
  

@internal
def _withdraw(
	assets: uint256,
	owner: address,
	receiver: address
) -> uint256:
	assert assets <= self._getMaxLiquidAssets()

	if msg.sender != owner:
		allowance: uint256 = self.allowances[owner][msg.sender]
		assert allowance >= assets
		# Unlimited approval (saves an SSTORE)
		if (allowance < max_value(uint256)):
			allowance = allowance - assets
			self.allowances[owner][msg.sender] = allowance
			# NOTE: Allows log filters to have a full accounting of allowance changes
			log Approval(owner, msg.sender, allowance)

	sharePrice: uint256 = self._getSharePrice()
	shares: uint256 = assets / sharePrice
	self.totalAssets -= assets
	self.balances[receiver] -= shares

	assert IERC20(asset).transfer(receiver, assets)

	log Withdraw(shares, owner, receiver, msg.sender, assets)
	return shares

@internal
def _takePerformanceFees(interestEarned: uint256) -> uint256:
	"""
		@notice takes total profits earned and takes fees for delegate and compounder
		@dev fees are stored as shares but input/ouput assets
		@return total amount of assets taken as fees
	"""
	if self.fees.performance == 0:
		return 0

	totalFees: uint256 = interestEarned * convert(self.fees.performance / FEE_COEFFICIENT, uint256)
	collectorFee: uint256 = 0
	
	if (
		self.fees.collector != 0 or
		msg.sender != self.delegate
	):
		collectorFee = totalFees * convert(self.fees.collector / FEE_COEFFICIENT, uint256)
		# caller gets collector fees in raw asset for easier mev
		self.totalAssets -= collectorFee
		assert IERC20(asset).transfer(msg.sender, collectorFee)

	# calculate shares to mint to delegate
	sharePrice: uint256 = self._getSharePrice()
	performanceFee: uint256 = (totalFees - collectorFee) / sharePrice

	# Not stored in balance so we can differentiate fees earned vs their own deposits, letting us slash fees on impariment.
	# earn fees in shares, not raw asset, so profit is vested like other users
	self.accruedFees += performanceFee
	self.balances[self] += performanceFee

	# inflate supply to take fees. reduce share price
	self.totalSupply += performanceFee

	log CollectInterest(interestEarned, self.accruedFees, sharePrice, collectorFee)
	return totalFees

# IERC20 action functions

@internal
def _transfer(sender: address, receiver: address, amount: uint256) -> bool:
	self.balances[sender] -= amount
	self.balances[receiver] += amount
	log Transfer(sender, receiver, amount)
	return True

@external
@nonreentrant("lock")
def transfer(to: address, amount: uint256) -> bool:
  return self._transfer(msg.sender, to, amount)

@external
@nonreentrant("lock")
def transferFrom(sender: address, receiver: address, amount: uint256) -> bool:
	# Unlimited approval (saves an SSTORE)
	if (self.allowances[sender][msg.sender] < max_value(uint256)):
		allowance: uint256 = self.allowances[sender][msg.sender] - amount
		self.allowances[sender][msg.sender] = allowance
		# NOTE: Allows log filters to have a full accounting of allowance changes
		log Approval(sender, msg.sender, allowance)

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


# IERC4626 internal functions
@internal
def _updateShares(amount: uint256, impair: bool = False):
	if impair:
		self.totalAssets -= amount
		# TODO RDT logic
		# TODO  log RDT rate change
	else:
		self.totalAssets += amount
		# TODO RDT logic
		# TODO  log RDT rate change

@view
@internal
def _getSharePrice() -> uint256:
	# returns # of assets per share

	# TODO RDT logic
	return self.totalAssets / self.totalSupply


@view
@internal
def _getShareAPR() -> int128:
	# returns rate of share price increase
	# TODO RDT logic
	return 0

@view
@internal
def _getMaxLiquidAssets() -> uint256:
	# maybe pass in owner: address param?
	# if user then their max withdrawable, if self then total vault liquidity

	# TODO account for RDT locked profits
	return self.totalAssets - self.totalDeployed

# IERC 3156 Flash Loan functions
@view
@external
def maxFlashLoan(token: address) -> uint256:
	if token != asset:
		return 0
	else:
		return self._getMaxLiquidAssets()

@view
@internal
def _getFlashFee(token: address, amount: uint256) -> uint256:
	if self.fees.flash == 0:
		return 0
	else:
		return self._getMaxLiquidAssets() * convert(self.fees.flash / FEE_COEFFICIENT, uint256)

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
	assert amount <= self._getMaxLiquidAssets()

	# give them the flashloan
	IERC20(asset).transfer(msg.sender, amount)

	fee: uint256 = self._getFlashFee(token, amount)
	
	# ensure they can receive flash loan
	# TODO says onFlashLoan not on interface
	assert IERC3156FlashBorrower(receiver).onFlashLoan(msg.sender, token, amount, fee, data) == keccak256("ERC3156FlashBorrower.onFlashLoan")
	
	# receive payment
	IERC20(asset).transferFrom(msg.sender, self, amount + fee)

	self._updateShares(fee)

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


@external
def permit(owner: address, spender: address, amount: uint256, expiry: uint256, signature: Bytes[65]) -> bool:
	"""
	@notice
		Approves spender by owner's signature to expend owner's tokens.
		See https://eips.ethereum.org/EIPS/eip-2612.
		Stolen from Yearn Vault code
		https://github.com/yearn/yearn-vaults/blob/74364b2c33bd0ee009ece975c157f065b592eeaf/contracts/Vault.vy#L765-L806
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


@external
@view
def convertToShares(assets: uint256) -> uint256:
	return assets * (self.totalAssets / self.totalSupply)


@external
@view
def convertToAssets(shares: uint256) -> uint256:
	return shares * (self.totalSupply / self.totalAssets)


@external
@view
def maxDeposit(receiver: address) -> uint256:
	"""
		add assets
	"""
	return max_value(uint256) - self.totalAssets

@external
@view
def maxMint(receiver: address) -> uint256:
	return max_value(uint256) - self.totalAssets

@external
@view
def maxWithdraw(owner: address) -> uint256:
	"""
		remove shares
	"""
	return self._getMaxLiquidAssets()

@external
@view
def maxRedeem(owner: address) -> uint256:
	"""
		remove assets
	"""
	return self._getMaxLiquidAssets() / self._getSharePrice()

@external
@view
def previewDeposit(assets: uint256) -> uint256:
	# TODO MUST be inclusive of deposit fees
	return min(max_value(uint256) - self.totalAssets, assets) / self._getSharePrice()

@external
@view
def previewMint(shares: uint256) -> uint256:
	# TODO MUST be inclusive of deposit fees
	return min(max_value(uint256) - self.totalAssets, shares * self._getSharePrice())

@external
@view
def previewWithdraw(assets: uint256) -> uint256:
	# TODO MUST be inclusive of withdraw fees
	return  min(self._getMaxLiquidAssets(), (max_value(uint256) - assets)) / self._getSharePrice()

@external
@view
def previewRedeem(shares: uint256) -> uint256:
	# TODO MUST be inclusive of withdraw fees
	return min(self._getMaxLiquidAssets(), shares * self._getSharePrice())

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

# IERC flashloan Events
# @TODO

# IERC2612 Events
# @TODO

# Pool Events
# @TODO

# Investing Events
event Impair:
	id: indexed(bytes32)
	amount: indexed(uint256)
	sharePrice: indexed(uint256)
	# todo add RDT rate

event Invest4626:
	vault: indexed(address)
	assets: indexed(uint256)
	shares: indexed(uint256)

event Divest4626:
	vault: indexed(address)
	assets: indexed(uint256)
	shares: indexed(uint256)

# fees
event CollectInterest:
	interest: indexed(uint256)
	performanceFee: indexed(uint256)
	sharePrice: indexed(uint256)
	# todo add RDT rate
	collectorFee: uint256

event ClaimPerformanceFee:
	recipient: indexed(address)
	fees: indexed(uint256)
	apr: indexed(int128)
	sharePrice: uint256


event ReferallFee:
	fees: indexed(uint256)
	referrer: indexed(address)
	depositor: address


# Param updates

event NewPendingDelegate:
	pendingGovernance: indexed(address)

event UpdateDelegate:
	governance: address # New active governance

event UpdateMinDeposit:
	depositLimit: uint256 # New active deposit limit

event UpdatePerformanceFee:
	performanceFee: uint16 # New active performance fee

event UpdateCollectorFee:
	collectorFee: uint16 # New active performance fee

event UpdateFlashFee:
	flashFee: uint16 # New active performance fee

event UpdateReferralFee:
	depositFee: uint16 # New active management fee
  
event UpdateWithdrawFee:
	depositFee: uint16 # New active management fee

event UpdateFeeRecipient:
	newRecipient: address # New active management fee
