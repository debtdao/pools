import boa
import ape
from eth_utils import to_checksum_address
import pytest
import logging
from boa.vyper.contract import BoaError
from hypothesis import given, settings
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, run_state_machine_as_test, rule, invariant
from .conftest import VESTING_RATE_COEFFICIENT, SET_FEES_TO_ZERO, DRATE, FRATE, INTEREST_TIMESPAN_SEC, ONE_YEAR_IN_SEC,  FEE_COEFFICIENT, MAX_PITTANCE_FEE
from ..conftest import MAX_UINT, ZERO_ADDRESS, POOL_PRICE_DECIMALS, INIT_POOL_BALANCE, INIT_USER_POOL_BALANCE
from ..utils.events import _find_event, _find_event_by

# (make vault another pool so we can double test at same time

# - test invest_vault
# get right shares back for assets deposited against vault price (do it 2x)
# properly increase initial principal (do it 2x)

def test_invest_vault_only_owner_can_call(pool, vault, admin, me, init_token_balances, _deposit):
    with boa.reverts():
        pool.invest_vault(vault, 100, sender=me)
    with boa.reverts():
        pool.invest_vault(vault, 100, sender=boa.env.generate_address())

    pool.invest_vault(vault, 100, sender=admin)


def test_invest_vault(pool, vault, base_asset, admin, me, init_token_balances, _deposit):
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == 0
    assert pool.vault_investments(vault) == 0
    assert vault.balanceOf(pool) == 0 # confirm we received shares
    assert vault.totalSupply() == 0
    assert vault.totalAssets() == 0
    assert base_asset.balanceOf(vault) == 0

    pool.invest_vault(vault, 100, sender=admin)

    pool_logs = pool.get_logs()
    # get events immediatelyafter function call before boa deletes
    invest_event = _find_event_by({ 'vault': vault.address, 'assets': 100, 'shares': 100 }, pool_logs)
    deposit_event = _find_event_by({ 'sender': pool.address, 'owner': pool.address, 'shares': 100, 'assets': 100 }, pool_logs)
    deposit_rev_event = _find_event_by({ 'fee_type': 2 , 'payer': vault.address, 'receiver': me, 'amount': 100, }, pool_logs)

    # print("investing events pool    :", invest_event, deposit_event, deposit_rev_event)

    assert deposit_event is not None
    assert invest_event is not None
    assert deposit_rev_event is not None
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == 100
    assert pool.vault_investments(vault) == 100
    assert vault.balanceOf(pool) == 100 # confirm we received shares
    assert vault.totalSupply() >= 100 # may have minflation fees
    assert vault.totalAssets() == 100
    assert base_asset.balanceOf(vault) == 100
    


def test_invest_vault_2x(pool, vault, base_asset, admin, me, init_token_balances, _deposit):
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == 0
    assert pool.vault_investments(vault) == 0
    assert vault.balanceOf(pool) == 0 # confirm we received shares
    assert vault.totalSupply() == 0
    assert vault.totalAssets() == 0
    assert base_asset.balanceOf(vault) == 0

    pool.invest_vault(vault, 100, sender=admin)

    pool_logs = pool.get_logs()
    # get events immediatelyafter function call before boa deletes
    invest_event = _find_event_by({ 'vault': vault.address, 'assets': 100, 'shares': 100 }, pool_logs)
    deposit_event = _find_event_by({ 'sender': pool.address, 'owner': pool.address, 'shares': 100, 'assets': 100 }, pool_logs)
    deposit_rev_event = _find_event_by({ 'fee_type': 2 , 'payer': vault.address, 'receiver': me, 'amount': 100, }, pool_logs)

    # print("investing events pool    :", invest_event, deposit_event, deposit_rev_event)

    assert deposit_event is not None
    assert invest_event is not None
    assert deposit_rev_event is not None
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == 100
    assert pool.vault_investments(vault) == 100
    assert vault.balanceOf(pool) == 100 # confirm we received shares
    assert vault.totalSupply() >= 100 # may have minflation fees
    assert vault.totalAssets() == 100
    assert base_asset.balanceOf(vault) == 100

    pool.invest_vault(vault, INIT_USER_POOL_BALANCE, sender=admin)

    pool_logs = pool.get_logs()
    # get events immediatelyafter function call before boa deletes
    invest_event2 = _find_event_by({ 'vault': vault.address, 'assets': INIT_USER_POOL_BALANCE }, pool_logs)
    deposit_event2 = _find_event_by({ 'sender': pool.address, 'owner': pool.address, 'assets': INIT_USER_POOL_BALANCE }, pool_logs)
    deposit_rev_event2 = _find_event_by({ 'fee_type': 2 , 'payer': vault.address, 'receiver': me, }, pool_logs)

    
    assert deposit_event2 is not None
    assert invest_event2 is not None
    assert deposit_rev_event2 is not None
    
    assert deposit_event2['shares'] > INIT_USER_POOL_BALANCE # mintflation from first depoist gives us more shares in second deposit
    assert invest_event2['shares'] > INIT_USER_POOL_BALANCE # mintflation from first depoist gives us more shares in second deposit
    assert invest_event2['shares'] == deposit_event2['shares']
    assert invest_event2['shares'] == deposit_rev_event2['amount']

    # TODO TEST rounding errors
    # expected_shares = 
    # assert invest_event2['shares'] == expected_shares

    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == 100 + INIT_USER_POOL_BALANCE
    assert pool.vault_investments(vault) == 100 + INIT_USER_POOL_BALANCE
    assert vault.balanceOf(pool) >= 100 + INIT_USER_POOL_BALANCE # confirm we received shares
    assert vault.totalSupply() >= 100 + INIT_USER_POOL_BALANCE # may have minflation fees
    assert vault.totalAssets() == 100 + INIT_USER_POOL_BALANCE
    assert base_asset.balanceOf(vault) == 100 + INIT_USER_POOL_BALANCE


def test_invest_vault_deployed_cant_be_withdrawn_from_pool(pool, vault, base_asset, admin, me, init_token_balances, _deposit):
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == 0
    assert pool.vault_investments(vault) == 0

    pool.invest_vault(vault, INIT_POOL_BALANCE, sender=admin)

    pool_logs = pool.get_logs()
    # get events immediatelyafter function call before boa deletes
    invest_event = _find_event_by({ 'vault': vault.address, 'assets': INIT_POOL_BALANCE, 'shares': INIT_POOL_BALANCE }, pool_logs)
    deposit_event = _find_event_by({ 'sender': pool.address, 'owner': pool.address, 'shares': INIT_POOL_BALANCE, 'assets': INIT_POOL_BALANCE }, pool_logs)
    deposit_rev_event = _find_event_by({ 'fee_type': 2 , 'payer': vault.address, 'receiver': me, 'amount': INIT_POOL_BALANCE, }, pool_logs)

    # print("investing events pool    :", invest_event, deposit_event, deposit_rev_event)

    assert deposit_event is not None
    assert invest_event is not None
    assert deposit_rev_event is not None
    assert pool.totalSupply() == INIT_POOL_BALANCE
    assert pool.totalAssets() == INIT_POOL_BALANCE
    assert pool.total_deployed() == INIT_POOL_BALANCE
    assert pool.vault_investments(vault) == INIT_POOL_BALANCE

    assert pool.maxFlashLoan(base_asset) == 0
    with boa.reverts():
        pool.withdraw(1, me, me, sender=me)
    

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
