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

