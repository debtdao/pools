
# Debt DAO Ponzinomics Test
# 1. pool can borrow from line where they are borrower (0 collateral, 0% interest)
# 1. cannot borrow from a position that isnt denominated in pool asset
# 1. Pool MUST repay all debt if total_assets are available and they are in  DEFUALT/INSOLVENT status
# 1. MUST NOT repay debt to line where pool isnt borrower
# 1. Pool shareholders cannot redeem debt assets, only users deposits
# 1. Can use debt assets to invest into LoC 
# 1. Can use debt assets to invest into vaults

# 1. can make a Spigot rev_recipient
# 1. can make a Spigot owner
# 1. Spigot rev_recipient can claim_rev via claimRevenue
# 1. Spigot can whitelist() Pool owner funcs
# 1. Spigot can operate() Pool owner funcs

# 1. 
# 1. can addCollateral to line escrow
# 1. can only addCollateral from liquid total_assets
# 1. addCollateral increases self.total_deployed
# 1. addCollateral reduces self.total_assets

