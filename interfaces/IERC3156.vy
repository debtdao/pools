# @version ^0.3.7

from interfaces import IERC3156FlashBorrower as IERC3156FlashBorrower

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
        receiver: IERC3156FlashBorrower,
        token: address,
        amount: uint256,
        data: Bytes[25000]
    ) -> bool: payable
