# https://github.com/liquity/ChickenBond


# Main Contracts

# Chicken Bond Factory
# takes pool and computs chicken bond addresss + curve pool for ddp + bddp tokens


# does a lot of farming management but we dont need to do that because all the farming is inherintly inside the pool 4626. 
# https://github.com/liquity/ChickenBond/blob/main/LUSDChickenBonds/src/ChickenBondManager.sol

# Mainly just an NFT contract. Has a bunch of randomg farmingstuff (crv guages,pickle jars, LQTY farms)
# for this random `setFinalExtraData()`` function
# controlled by manager contract
# https://github.com/liquity/ChickenBond/blob/main/LUSDChickenBonds/src/BondNFT.sol

# simple ERC20 that can only be mint/burned by Manager contract
# https://github.com/liquity/ChickenBond/blob/main/LUSDChickenBonds/src/BLUSDToken.sol