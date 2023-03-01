from vyper.interfaces import ERC20 as IERC20

interface IERC3156FlashBorrower:
	def onFlashLoan(
		initiator: address,
		token: address,
		amount: uint256,
		fee: uint256,
		data:  Bytes[25000]
	) -> bytes32: payable

interface IERC20Mintable:
    def mint(to: address, amount: uint256) -> bool: nonpayable

implements: IERC3156FlashBorrower

@external
def onFlashLoan(
    initiator: address,
    token: address,
    amount: uint256,
    fee: uint256,
    data:  Bytes[25000]
) -> bytes32:
    IERC20Mintable(token).mint(self, fee) # assume dummy token
    IERC20(token).approve(msg.sender, amount + fee)
    return keccak256("ERC3156FlashBorrower.onFlashLoan")