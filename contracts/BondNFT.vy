# @version ^0.3.7

# TODO make sure u check all logic in contracts inherited by OG BindNFT.sol
# TODO implement ERC721Enumberable. Look at snekmate


enum BOND_STATUS:
    NULL
    ACTIVE
    CHIKKIN_OUT
    CHIKKIN_IN

interface IBondManager:
    def get_bond_data(_tokenID: uint256) -> (uint256, uint64, uint64, uint64, BOND_STATUS): nonpayable

interface IBondNFT:
    def mint(_bonder: address, _permanentSeed: uint256) -> (uint256, uint80): nonpayable
    def set_final_extra_data(_bonder: address, _tokenID: uint256, _permanentSeed: uint256) -> uint80: nonpayable
    def bond_manager() -> address: nonpayable
    def get_bond_amount(_tokenID: uint256) -> uint256: nonpayable
    def get_bond_start_time(_tokenID: uint256) -> uint256: nonpayable
    def get_bond_end_time(_tokenID: uint256) -> uint256: nonpayable
    def get_bond_initial_half_dna(_tokenID: uint256) -> uint80: nonpayable
    def get_bond_initial_dna(_tokenID: uint256) -> uint256: nonpayable
    def get_bond_final_half_dna(_tokenID: uint256) -> uint80: nonpayable
    def get_bond_final_dna(_tokenID: uint256) -> uint256: nonpayable
    def get_bond_status(_tokenID: uint256) -> uint8: nonpayable
    def get_bond_extra_data(_tokenID: uint256) -> (uint80, uint80, uint32, uint32, uint32): nonpayable
    # OG chicken bon solidity interface for backwards compatability
    def setFinalExtraData(_bonder: address, _tokenID: uint256, _permanentSeed: uint256) -> uint80: nonpayable
    def chickenBondManager() -> address: nonpayable
    def getBondAmount(_tokenID: uint256) -> uint256: nonpayable
    def getBondStartTime(_tokenID: uint256) -> uint256: nonpayable
    def getBondEndTime(_tokenID: uint256) -> uint256: nonpayable
    def getBondInitialHalfDna(_tokenID: uint256) -> uint80: nonpayable
    def getBondInitialDna(_tokenID: uint256) -> uint256: nonpayable
    def getBondFinalHalfDna(_tokenID: uint256) -> uint80: nonpayable
    def getBondFinalDna(_tokenID: uint256) -> uint256: nonpayable
    def getBondStatus(_tokenID: uint256) -> uint8: nonpayable
    def getBondExtraData(_tokenID: uint256) -> (uint80, uint80, uint32, uint32, uint32): nonpayable

event Transfer:
    _from: indexed(address)
    _to: indexed(address)
    _tokenID: indexed(uint256)

struct BondData:
    initial_half_dna: uint80 
    final_half_dna: uint80 
    trove_size: uint32          # Debt in ddp token
    # DONT NEED lqtyAmount: uint32         # Holding LQTY, staking or deposited into Pickle
    # DONT KNOW YET curveGaugeSlopes: uint32   # For 3CRV and Frax pools combined

# implements: IBondNFT
# implements: IERC721


# IERC721 vars
total_supply: public(uint256)
owners: HashMap[uint256, address]
approvals: HashMap[uint256, address] # singular approved spender for token
operators: HashMap[address, HashMap[address, bool]] # opproved operators for an owner
# IERC721Enumerable
balances: HashMap[address, uint256]

# Chikkin Bond vars
transfer_lockout_period_seconds: immutable(uint256)
bond_manager: immutable(address)
bond_data: HashMap[uint256, BondData]

@external
def __init__(
        _name: String[30],
        _symbol: String[18],
        _troveManagerAddress: address,
        # _initialArtworkAddress: address ,
        _transfer_lockout_epoch_seconds: uint256,
        _bond_manager: address
):
    bond_manager = _bond_manager
    transfer_lockout_period_seconds = _transfer_lockout_epoch_seconds
    assert True

@external
def mint(_bonder: address, _permanentSeed: uint256) -> (uint256, uint80):
    assert msg.sender == bond_manager

    # We actually inc total_supply in `_mint`
    tokenID: uint256 = self.total_supply + 1
    # //Record first half of DNA
    initial_half_dna: uint80 = self.get_half_dna(tokenID, _permanentSeed)
    self.bond_data[tokenID] = BondData({
        initial_half_dna: initial_half_dna,
        final_half_dna: 0,
        trove_size: 0,
    })

    self._mint(_bonder, tokenID)

    return (tokenID, initial_half_dna)

### Normie NFT Shit
@external 
def transfer(_to: address, _tokenID: uint256):
    self._transfer(msg.sender, _to, _tokenID)

@external 
def transferFrom(_from: address, _to: address, _tokenID: uint256):
    self._transfer(_from, _to, _tokenID)


### internal Chikkin Bond logic

@view
@internal
def get_half_dna(_tokenID: uint256, _permanentSeed: uint256) -> uint80:
    return convert(convert(keccak256(_abi_encode(_tokenID, block.timestamp, _permanentSeed)), uint256), uint80)

@external
def set_final_extra_data(_bonder: address, _tokenID: uint256, _permanentSeed: uint256) -> uint80:
    assert msg.sender == bond_manager

    # // let’s build the struct first in memory
    bond_data: BondData = self.bond_data[_tokenID]

    new_dna: uint80  = self.get_half_dna(_tokenID, _permanentSeed)
    bond_data.final_half_dna = new_dna

    # // Liquity Data
    # // Trove
    # bond_data.troveSize = convert(troveManager.getTroveDebt(_bonder), uint32)
    # // LQTY
    # uint256 pickleLQTYAmount
    # if (pickleLQTYJar.total_supply() > 0) {
    #     pickleLQTYAmount = (pickleLQTYJar.balanceOf(_bonder) + pickleLQTYFarm.balanceOf(_bonder)) * pickleLQTYJar.getRatio()
    # }
    # bond_data.lqtyAmount = _uint256ToUint32(
    #     lqtyToken.balanceOf(_bonder) + lqtyStaking.stakes(_bonder) + pickleLQTYAmount
    # )
    # // Curve Gauge votes
    # (uint256 curveLUSD3CRVGaugeSlope,,) = curveGaugeController.vote_user_slopes(_bonder, curveLUSD3CRVGauge)
    # (uint256 curveLUSDFRAXGaugeSlope,,) = curveGaugeController.vote_user_slopes(_bonder, curveLUSDFRAXGauge)
    # bond_data.curveGaugeSlopes = _uint256ToUint32((curveLUSD3CRVGaugeSlope + curveLUSDFRAXGaugeSlope) * CURVE_GAUGE_SLOPES_PRECISION)

    # // finally copy from memory to storage
    # self.bond_data[_tokenID] = bond_data

    return new_dna

### IERC721

# from vyper.interfaces import ERC721 as IERC721
@internal
def _mint(_to: address,_tokenID: uint256):
    assert _to != empty(address) # dev: "ERC721: mint _to the zero address"
    self._assert_non_existant(_tokenID) # dev: "ERC721: token already minted"

    # TODO hunt down solidity traces  :'(
    # _beforeTokenTransfer(empty(address), _to, _tokenID, 1)

    self.total_supply += 1
    self._transfer(empty(address), _to, _tokenID)
    # _addTokenToAllTokensEnumeration(_tokenId)

    # TODO hunt down solidity traces  :'(
    # _afterTokenTransfer(empty(address), _to, _tokenId, 1)

@internal
def _burn(_tokenID: uint256):
    # OZ ERC721
    # https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.8.0/contracts/token/ERC721/ERC721.sol
    owner: address = self._owner_of(_tokenID)

    # TODO hunt down solidity traces  :'(
    # _beforeTokenTransfer(owner, address(0), _tokenID, 1)

    self._transfer(owner, empty(address), _tokenID)
    # _removeTokenFromAllTokensEnumeration(_tokenId)

    # TODO hunt down solidity traces  :'(
    # _afterTokenTransfer(owner, address(0), _tokenID, 1)

@internal
def _transfer(_from: address, _to: address, _tokenID: uint256, _batch_size: uint256 = 1):
    self._is_approved_or_owner(_from, _tokenID)
    #clear approvals from previous owner
    self.approvals[_tokenID] = empty(address)
    # transfer token post approval checks
    self.owners[_tokenID] = _to

    # OZ ERC721
    # https://github.com/OpenZeppelin/openzeppelin-contracts/blob/49c0e4370d0cc50ea6090709e3835a3091e33ee2/contracts/token/ERC721/ERC721.sol#L467-L482
    if _batch_size != 0:
        if _from != empty(address):
            self.balances[_from] -= _batch_size
            # _removeTokenFromOwnerEnumeration(_from, _tokenId)
        if _to != empty(address):
            self.balances[_to] += _batch_size
            # _addTokenToOwnerEnumeration(_to, _tokenId)

    # #OZ ERC721 
    # https://github.com/OpenZeppelin/openzeppelin-contracts/blob/49c0e4370d0cc50ea6090709e3835a3091e33ee2/contracts/token/ERC721/ERC721.sol#L429-L451
    #  assert _checkOnERC721Received(from, to, tokenId, data), "ERC721: transfer to non ERC721Receiver implementer");
    #     if (to.isContract()) {
    #     try IERC721Receiver(to).onERC721Received(_msgSender(), from, tokenId, data) returns (bytes4 retval) {
    #         return retval == IERC721Receiver.onERC721Received.selector;
    #     } catch (bytes memory reason) {
    #         if (reason.length == 0) {
    #             revert("ERC721: transfer to non ERC721Receiver implementer");
    #         } else {
    #             /// @solidity memory-safe-assembly
    #             assembly {
    #                 revert(add(32, reason), mload(reason))
    #             }
    #         }
    #     }
    # } else {
    #     return true;
    # }

    # OZ ERC721Enumerable._beforeTokenTransfer
    # https://github.com/OpenZeppelin/openzeppelin-contracts/blob/49c0e4370d0cc50ea6090709e3835a3091e33ee2/contracts/token/ERC721/extensions/ERC721Enumerable.sol#L66-L85
    # if (batchSize > 1) {
    #     // Will only trigger during construction. Batch transferring (minting) is not available afterwards.
    #     revert("ERC721Enumerable: consecutive transfers not supported")
    # }

    # uint256 tokenId = firstTokenId
    if _from == empty(address) :
        # add to _mint()
        assert True
    elif _from != _to :
        assert True
    
    if _to == empty(address) :
        # add to _mint()
        assert True
    elif _to != _from :
        assert True

    # BondNFT._beforeTokenTransfer
    # https://github.com/liquity/ChickenBond/blob/89c10d777bb1fabdce6ec54dbf67265984c9724f/LUSDChickenBonds/src/BondNFT.sol#L158-L170
    if _from != empty(address) :
        _: uint256 = empty(uint256)
        __: uint64 = empty(uint64)
        ___: uint64 = empty(uint64)
        endTime: uint64 = empty(uint64)
        status: BOND_STATUS = empty(BOND_STATUS)
        (_, __, ___, endTime, status) = IBondManager(bond_manager).get_bond_data(_tokenID)

        assert status == BOND_STATUS.ACTIVE or block.timestamp >= convert(endTime, uint256) + transfer_lockout_period_seconds
            # "BondNFT: cannot transfer during lockout period"

        # super._beforeTokenTransfer(_from, _to, _tokenID)

@view
@internal
def _is_approved_or_owner(_caller: address, _tokenID: uint256) -> bool:
    return self.owners[_tokenID] == _caller or self.approvals[_tokenID] == _caller

@view
@internal
def _owner_of(_tokenID: uint256) -> address:
    return self.owners[_tokenID]


@view
@internal
def _assert_existing(_tokenID: uint256):
    assert self._is_existant(_tokenID)

@view
@internal
def _assert_non_existant(_tokenID: uint256):
    assert not self._is_existant(_tokenID)


@view
@internal
def _is_existant(_tokenID: uint256) -> bool:
    return empty(address) != self.owners[_tokenID]
