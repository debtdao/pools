# @version ^0.3.7

interface IBondNFT:
    def mint(_bonder: address, _permanentSeed: uint256) -> (uint256, uint80): nonpayable
    def set_final_extra_data(_bonder: address, _tokenID: uint256, _permanentSeed: uint256) -> uint80: nonpayable
    def chicken_bond_manager() -> address: nonpayable
    def get_bond_amount(_tokenID: uint256) -> uint256: nonpayable
    def get_bond_start_time(_tokenID: uint256) -> uint256: nonpayable
    def get_bond_end_time(_tokenID: uint256) -> uint256: nonpayable
    def get_bond_initial_half_dna(_tokenID: uint256) -> uint80: nonpayable
    def get_bond_initial_dna(_tokenID: uint256) -> uint256: nonpayable
    def get_bond_final_half_dna(_tokenID: uint256) -> uint80: nonpayable
    def get_bond_final_dna(_tokenID: uint256) -> uint256: nonpayable
    def get_bond_status(_tokenID: uint256) -> uint8: nonpayable
    def get_bond_extra_data(_tokenID: uint256) -> (uint80, uint80, uint32, uint32, uint32): nonpayable