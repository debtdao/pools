# (make vault another pool so we can double test at same time

# - test invest_vault
# get right shares back for assets deposited against vault price (do it 2x)
# properly increase initial principal (do it 2x)

# - test divest_vault
# burn proper amount of shares for assets (do it 2x),
# no profit, no profit (do it 2x),
# no profit, profit (do it 2x),
# loss,
# cant claim profit until initial principal is recouped
# claim profit and then realize a loss (is it possible??)

# - test multi invest + divest - 
# properly divest -  no profit, profit, loss, profit, no profit, profit, loss (to 0 then invest again), profit
# properly impair - loss, profit (2x),


# 4626 Vault Invest/Divest

# (done) owner priviliges on investment functions
# vault_investment goes up by _amount 
# only vault that gets deposited into has vault_investment changed
# emits InvestVault event X params
# emits RevenueGenereated event with X params and FEE_TYPES.DEPOSIT
# investing in vault increased total_deployed by _amount
# investing in vault increases vault.balanceOf(pool) by shares returned in vault.deposit
# investing in vault increases vault.balanceOf(pool) by expected shares using _amount and pre-deposit share price
# 
# divesting vault decreases total_deployed
# divesting vault 
# emits DivestVault event with X params
# emits RevenueGenereated event with X params and FEE_TYPES.WITHDRAW
# divesting vault decreases vault.balanceOf(pool)
# divesting vault decreases vault.balanceOf(pool) by shares returned in vault.withdraw
# divesting vault decreases vault.balanceOf(pool) by expected shares using _amount and pre-withdraw share price
