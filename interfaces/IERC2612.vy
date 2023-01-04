# @version ^0.3.7

interface IERC2612:
    # permit() in solidity - function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s)
    def permit(owner: address, spender: address, amount: uint256, deadline: uint256, signature: Bytes[65]) -> bool: nonpayable
    def nonces(owner: address ) -> uint256: view
    def DOMAIN_SEPARATOR() -> bytes32: view