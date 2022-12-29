interface IERC2612:
    def permit(owner: address, spender: address, value: uint256, deadline: uint256, v: uint8, r: bytes32, s: bytes32): payable
    def nonces(owner: address ) -> uint256: view
    def DOMAIN_SEPARATOR() -> bytes32: view