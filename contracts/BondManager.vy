# @version ^0.3.7


# https://github.com/liquity/ChickenBond


# Main Contracts

enum BOND_STATUS:
    NULL
    ACTIVE
    CHIKKIN_OUT
    CHIKKIN_IN

CHICKEN_IN_AMM_FEE: immutable(uint256)
pending_reserves: uint256        # Total pending LUSD. It will always be in SP (B.Protocol)
permanent_reserves: uint256      # Total permanent LUSD
bamm_token_debt: uint256       # Amount “owed” by B.Protocol to ChickenBonds, equals deposits - withdrawals + rewards
# yTokensHeldByCBM: uint256   # Computed balance of Y-tokens of LUSD-3CRV vault owned by this contract
                            # (to prevent certain attacks where attacker increases the balance and thus the backing ratio)


def __init__(

):
    
# Chicken Bond Factory
# takes pool and computs chicken bond addresss + curve pool for ddp + bddp tokens
# I think main issue btw us and normal chicken bond is all our yield is internalized inside of the base token itself. \
# This might make it difficuly/impossible to have the reserve vs permanent pool. Or we will have to extra accounting logic around 4626 pool shares

# importnat functions 
_calcUpdatedAccrualParameter

# does a lot of farming management but we dont need to do that because all the farming is inherintly inside the pool 4626. 
# https://github.com/liquity/ChickenBond/blob/main/LUSDChickenBonds/src/ChickenBondManager.sol

# Mainly just an NFT contract. Has a bunch of randomg farmingstuff (crv guages,pickle jars, LQTY farms)
# for this random `setFinalExtraData()`` function
# controlled by manager contract
# https://github.com/liquity/ChickenBond/blob/main/LUSDChickenBonds/src/BondNFT.sol

#important functions
setFinalExtraData
getHalfDna

# simple ERC20 that can only be mint/burned by Manager contract
# https://github.com/liquity/ChickenBond/blob/main/LUSDChickenBonds/src/BLUSDToken.sol