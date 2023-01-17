interface IRevenueGenerator:
	def owner() -> address: view
	def pending_owner() -> address: view
	def set_owner(_new_owner: address) -> bool: nonpayable
	def accept_owner() -> bool: nonpayable

	def rev_type() -> uint64: pure
	def rev_recipient() -> address: view
	def pending_rev_recipient() -> address: view
	def set_rev_recipient(_new_recipient: address) -> bool: nonpayable
	def accept_rev_recipient() -> bool: nonpayable

	# @notice how many tokens can be sent to fee_recipient by caller
	def claimable_rev(_token: address) -> uint256: view
	#  @notice optional. MAY do push payments. if push payments then revert.
	def claim_rev(_token: address, _amount: uint256) -> uint256: nonpayable
	# @notice requires mutualConsent. Must return IFeeGenerator.payInvoice.selector if function is supported.
	# @dev MUST be able to accept native ETH
	# NOTE: _note may be an EIP-712 structured signed message
	def accept_invoice(_from: address, _token: address, _amount: uint256, _note: String[2048]) -> uint256: payable

event NewPendingOwner:
	pending_owner: indexed(address)

event UpdateOwner:
	owner: indexed(address) # New active governance

event NewPendingRevRecipient:
	new_recipient: address 	# New active management fee

event AcceptRevRecipient:
	new_recipient: address 	# New active management fee

event RevenueGenerated:		# standardize revenue reporting for offchain analytics
	payer: indexed(address) # where fees are being paid from
	token: indexed(address) # where fees are being paid from
	revenue: indexed(uint256) # tokens paid in fees, denominated in 
	amount: uint256			# total assets that fees were generated on (user deposit, flashloan, loan principal, etc.)
	fee_type: uint64 		# maps to app specific fee enum or eventually some standard fee code system
	receiver: address 		# who is getting the fees paid

event RevenueClaimed:
	recipient: indexed(address)
	amount: indexed(uint256)

event UpdateFee:
	fee_type: indexed(uint256)
	fee_bps: indexed(uint16)

event InvoicePaid:
	client: indexed(address)
	rev_type: indexed(uint256)
	note: indexed(String[2048])
