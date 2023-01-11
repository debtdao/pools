# @version ^0.3.7

# TODO make sure u check all logic in contracts inherited by OG BondNFT.sol
# TODO implement ERC721Enumberable. Look at snekmate


# """
# @title    Debt Dominatrix Bondage Contract
# @author   Kiba Gateaux
# @notice 	
# @dev 	
#                                   *
#                                 /"^"\
#                                ""=="7|             *
#                              ."  .' :            /"^^\
#                             :   *   :           ("   ")
#                            .'  .'   `.         ("    ")
#                            '`""    `",`--_.._--""   ")


# # uncomment lines for cat vs bunny girl


#                          ___ .~- ` `' "' ` -~. ____
#                          :~+.-`  .-"-.  .-"~._  `-.+~:
#                          !  /  -`     `       `'--~:.l
#                          :'=:      ^       ^     :='.:
#                         $$SS$$                   SS$$P"        
#                         :$S$$;  .=/==.   .==\=.  :SS$$          
#                         /SSSS$$                  $S$S$;         
#                       -':$$$$$$; .mPm.     .mPm. :$S$$S$-'       
#                         $$$$$$$$                 $$S$$S$;        
#                        :$$S$$$$;       d:       :$SS$$S$$        
#                        $$$S$$$$$\      ""       $$S$$$S$$.       
#                        $$$S$$$$N \  ._..._.    d$S$$$$S$$$$p 
#                        $$SS$$$MMm.j         .d$S$$$$S;""^^""    
#                        :SS$$$$MMMMMb.     .d$$S$$$$SS$          
#                      '-'S$$$$MMMMMMMMMmmmMMSSS$$$$SS$;          
#                         :$mMOMMMMMMMMMMMMMMS$$$S$SS$$'-'        
#                  __..mmMMMMMMOOMMMMMMMMMMMOSSSS$SS$$;           
#              .mMMMMMMMMMMMMMMMMOOOMMMMMMOOMMS$SSS$$P            
#            .dMMMMMMMMMMMMMMMMMMMMMOOOOOOMMMMMMMSSSP             
#           dMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMm.          
#          dMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMb         
#         :MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM;        
#         MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM        
#        :MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM;        
#        MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM         
#       :MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM;         
#       MMMMMMMMMMOMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMOM;          
#      :MMMMMMMMMMOMMOMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMO;          
#      MMMMMMMMMMOMMMMOMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMb          
#     :MMMMMMMMMMOMMMMOMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM;         
#     MMMMMMMMMMMMMMMMOMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM         
#     M^"MMMMMMM;:MMMMOMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM;         
#    :     ""^^:  MMMMMOMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMP          
#    |         ;  :MMMMMOOMMMMMMMMMMMMMMMMMMMMMMMMMMMP'           
#    ;        :    MMMMMMMOBUGMMMMMMMMMMMMMMMMMMMMMM'             
#   :         ;    :MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM              
#   :        :      TMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM;              
#   |        ;       TMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM              
#   |       :         TMMMMMMMMMMMMMMMMMMMMMMMMMMMMMb             
#   ;       ;          TMMMMMMMMMMMMMMMMMMMMMMMMMMMMMb            
#   :       :           TMMMMMMMMMMMMMMMMMMMMMMMMMMMMMb           
#    ;       `.          TMMMMMMMMMMMMMMMMMMMMMMMMMMMMMb          
#    :         \          TMMMMMMMMMMMMMMMMMMMMMMMMMMMMMb.        
#     \         \          TMMMMMMMMMMMMMMMMMMMMMMMMMMMMMb`.      
#      \         \         ;MMMMMMMMMMMMMMMMMMMMMMMMMMMMM8b \     
#       \         ;        ;MMMMMMMMMMMMMMMMMMMMMMMMMMMM888; ;    
#        \        :        8MMMMMMMMMMMMMMMMMMMMM88888888888.^.   
#         \        \       88MMMMMMMMM8888888888888888888Pd8b  \  
#          `.       \  bug T8888888888888888888888888888Pd888b._; 
#            `.      \   __J88888888888888888888888888888888888; ;
#              `.     `-' _,`T8888888888888888888888888888888888/ 
#                `.      .gb.88888888888888888888888888888888Pd8  
#                  `.   d88888bT888888888888888888888888888P8d88  
#                    `.d8888888888888888888888888888888888888888  
#                     :88888888888888888888888888888888888888888  
#                      T888888888888888888888888888888888888888;  
#                       "^8888Pd8888888888888888888888888888888  
# """

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

# from vyper.interfaces import ERC721 as IERC721
# implements: IBondNFT
# implements: IERC721

# ERC721_RECEIVER: constant(bytes4) = method_id("onERC721Received(address,address,uint256,bytes)")
ERC721_RECEIVER: constant(bytes4) = 0x150b7a02

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

@internal
def _mint(_to: address,_tokenID: uint256):
    assert _to != empty(address) # dev: "ERC721: mint _to the zero address"
    assert not self._is_existant(_tokenID) # dev: "ERC721: token already minted"

    self.total_supply += 1
    self._transfer(empty(address), _to, _tokenID)
    # _addTokenToAllTokensEnumeration(_tokenId)

@internal
def _burn(_tokenID: uint256):
    # OZ ERC721
    # https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.8.0/contracts/token/ERC721/ERC721.sol
    owner: address = self._owner_of(_tokenID)

    self.total_supply -= 1
    self._transfer(owner, empty(address), _tokenID)
    # _removeTokenFromAllTokensEnumeration(_tokenId)

@internal
def _transfer(_from: address, _to: address, _tokenID: uint256, _batch_size: uint256 = 1):
    self._is_approved_or_owner(_from, _tokenID)
    #clear approvals from previous owner
    self.approvals[_tokenID] = empty(address)

    # OZ ERC721
    # https://github.com/OpenZeppelin/openzeppelin-contracts/blob/49c0e4370d0cc50ea6090709e3835a3091e33ee2/contracts/token/ERC721/ERC721.sol#L467-L482
    if _batch_size != 0:
        if _from != empty(address):
            self.balances[_from] -= _batch_size
            # _removeTokenFromOwnerEnumeration(_from, _tokenId)
        if _to != empty(address):
            self._assert_can_accept_erc721(_to, _tokenID)
                # transfer token post approval checks
            self.balances[_to] += _batch_size
            # _addTokenToOwnerEnumeration(_to, _tokenId)

    self.owners[_tokenID] = _to

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

@internal
def _assert_can_accept_erc721(_to: address, _tokenID: uint256):
    """
    @notice     Stolen from OZ ERC721 https://github.com/OpenZeppelin/openzeppelin-contracts/blob/49c0e4370d0cc50ea6090709e3835a3091e33ee2/contracts/token/ERC721/ERC721.sol#L429-L451
    """
    if _to.is_contract:
        response: Bytes[32] = raw_call(
            _to,
            method_id("onERC721Received(address,address,uint256,bytes)"),
            max_outsize=32,
            revert_on_failure=True ,
        )

        assert ERC721_RECEIVER == _abi_decode(response, bytes4)

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
def _is_existant(_tokenID: uint256) -> bool:
    return empty(address) != self.owners[_tokenID]


