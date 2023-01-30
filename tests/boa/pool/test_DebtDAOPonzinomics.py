
# Debt DAO Ponzinomics Test
# 1. pool MUST borrow from line where they are borrower
# ??y/n?? pool MUST NOT be able to post collateral to loans
# 1. 
# 1. cannot borrow from a position that isnt denominated in pool ASSET
# 1. Pool MUST repay all debt if total_assets are available and they are in  DEFUALT/INSOLVENT status
# 1. anyone can call emergency_repay to repay debt on defaulted lines
# 1. emergency_repay MUST NOT work on ACTIVE lines
# 1. emergency_repay MUST slash accrued_fees and pool assets if successful
# 1. Pool MUST be able to open multiple positions per line. 
# 1. Pool MUST be able to own multiple lines. 
# 1. Pool can only borrow from one lender per line. Line constraint bc can only borrow ASSET, lender can only create one position per line.
# 1. MUST be able to track initial principal drawn vs repaid
# 1. MUST be able to track initial interest owed on a line

# 1. MUST NOT repay debt to line where pool isnt borrower
# 1. Pool shareholders MUST NOT redeem debt assets, only users deposits
# 1. MUST be able to use debt assets to invest into LoC 
# 1. MUST be able to use debt assets to invest into vaults
# 1. 

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

