interface IFeeGenerator:
	def owner() -> address: nonpayable
	def pending_owner() -> address: nonpayable
	def set_owner(_new_owner: address) -> bool: nonpayable
	def accept_owner() -> bool: nonpayable

	def fee_recipient() -> address: nonpayable
	def pending_fee_recipient() -> address: nonpayable
	def set_fee_recipient(_new_recipient: address) -> bool: nonpayable
	def accept_fee_recipient() -> bool: nonpayable

	#  @notice optional. MAY do push payments. if push payments then revert\;
	def claim_fees(_token: address) -> uint256: nonpayable
	#  @notice requires mutualConsent. Must return IFeeGenerator.payInvoice.selector if function is supported.
	# NOTE: _note may be an EIP-712 structured signed message
	def accept_invoice(_from: address, _token: address, _amount: uint256, _note: String[2048]) -> uint256: nonpayable

event NewPendingOwner:
	pending_owner: indexed(address)

event UpdateOwner:
	owner: indexed(address) # New active governance

event NewPendingFeeRecipient:
	new_recipient: address # New active management fee

event AcceptFeeRecipient:
	fee_recipient: address # New active management fee

event FeesGenerated:
	payer: indexed(address) # where fees are being paid from
	token: indexed(address) # where fees are being paid from
	fee: indexed(uint256) # tokens paid in fees, denominated in 
	amount: uint256 # total assets that fees were generated on (user deposit, flashloan, loan principal, etc.)
	receiver: address # who is getting the fees paid
	fee_type: uint256 # maps to app specific fee enum or eventually some standard fee code system

event FeesClaimed:
	recipient: indexed(address)
	fees: indexed(uint256)

event UpdateFee:
	fee_type: indexed(uint256)
	fee_bps: indexed(uint16)

event InvoicePaid:
	client: indexed(address)
	fee_type: indexed(uint256)
	note: indexed(String[2048])
